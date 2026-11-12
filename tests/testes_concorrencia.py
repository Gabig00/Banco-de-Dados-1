#!/usr/bin/env python3
"""Testes reais com duas conexões psql, sem dependências Python adicionais.
Execute APENAS em banco descartável após dados_demonstracao.sql.
Cria pedidos/baixas que permanecem no banco para inspeção.
Conexão por PGHOST, PGPORT, PGUSER, PGDATABASE e .pgpass (ou PGPASSWORD no CI).
PSQL_BIN permite indicar o executável do psql. Não escreve nem imprime senhas.
"""
import concurrent.futures
import os
import subprocess
import threading

PSQL = os.environ.get('PSQL_BIN', 'psql')

def sql(text, ok=True):
    result = subprocess.run([PSQL, '-X', '-v', 'ON_ERROR_STOP=1', '-Atq', '-c', text],
                            text=True, capture_output=True)
    if ok and result.returncode:
        raise AssertionError(result.stderr)
    return result

def simultaneous(commands):
    barrier = threading.Barrier(len(commands))
    def worker(command):
        barrier.wait()
        return sql(command, ok=False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(commands)) as pool:
        return list(pool.map(worker, commands))

def main():
    product, depot, client, bank, title = map(int, sql("""
        SELECT p.id,d.id,c.id,b.id,t.id FROM mm.produto p
        CROSS JOIN mm.deposito d CROSS JOIN cad.cliente c
        CROSS JOIN fi.conta_bancaria b CROSS JOIN fi.titulo t
        WHERE p.sku='PA-CADEIRA' AND d.nome='Principal' AND t.tipo='RECEBER'
        AND t.valor=450 LIMIT 1
    """).stdout.strip().split('|'))
    before = sql(f'SELECT quantidade FROM mm.estoque WHERE produto_id={product} AND deposito_id={depot}').stdout.strip()
    assert float(before) == 5, 'Use uma cópia nova dos dados de demonstração.'
    orders = []
    for _ in range(2):
        order = int(sql(f'INSERT INTO sd.pedido(cliente_id,deposito_id) VALUES({client},{depot}) RETURNING id').stdout.strip())
        sql(f'INSERT INTO sd.pedido_item(pedido_id,produto_id,quantidade,preco_unitario) VALUES({order},{product},4,150)')
        orders.append(order)
    results = simultaneous([
        f'BEGIN; CALL sd.faturar_pedido({order},CURRENT_DATE+10); SELECT pg_sleep(1); COMMIT;'
        for order in orders
    ])
    assert sum(r.returncode == 0 for r in results) == 1, [r.stderr for r in results]
    assert any('Estoque insuficiente' in r.stderr for r in results), 'Esperava falha de estoque.'
    remaining = sql(f'SELECT quantidade FROM mm.estoque WHERE produto_id={product} AND deposito_id={depot}').stdout.strip()
    assert float(remaining) == 1, remaining
    assert sql(f"SELECT count(*) FROM sd.pedido WHERE id IN ({orders[0]},{orders[1]}) AND status='FATURADO'").stdout.strip() == '1'
    print('PASSOU: duas vendas concorrentes; apenas uma fatura e o saldo termina em 1.')

    key = '44444444-4444-4444-8444-444444444444'
    command = f"BEGIN; CALL fi.baixar_titulo({title},{bank},100,'{key}'); SELECT pg_sleep(1); COMMIT;"
    results = simultaneous([command, command])
    assert all(r.returncode == 0 for r in results), [r.stderr for r in results]
    assert sql(f"SELECT count(*) FROM fi.baixa WHERE chave_idempotencia='{key}'").stdout.strip() == '1'
    assert float(sql(f'SELECT saldo FROM fi.v_titulos_abertos WHERE id={title}').stdout.strip()) == 150
    print('PASSOU: duas baixas concorrentes com a mesma chave geram uma única liquidação.')

if __name__ == '__main__':
    main()
