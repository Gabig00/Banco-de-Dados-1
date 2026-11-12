#!/usr/bin/env python3
"""Testes adicionais de concorrência e 200 operações com oráculo independente.
Usar SOMENTE em banco descartável, com V007 e dados de demonstração.
Deixa dados identificados TEST- no banco. Sem bibliotecas Python de terceiros.
Conexão via PG*, executável opcional PSQL_BIN. Cada processo abre uma conexão real.
"""
import concurrent.futures
from decimal import Decimal
import os
import random
import subprocess
import threading
import uuid

PSQL = os.environ.get('PSQL_BIN', 'psql')
TAG = 'TEST-' + uuid.uuid4().hex[:12]

def sql(command, ok=True):
    result = subprocess.run([PSQL, '-X', '-Atq', '-v', 'ON_ERROR_STOP=1', '-c',
                             "SET statement_timeout='12s'; SET lock_timeout='8s'; " + command],
                            text=True, capture_output=True, timeout=18)
    if ok and result.returncode:
        raise AssertionError(result.stderr)
    return result

def scalar(command):
    return sql(command).stdout.strip()

def race(commands, successes, error=None):
    gate = threading.Barrier(len(commands))
    def run(command):
        gate.wait()
        return sql(command, ok=False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(commands)) as pool:
        results = list(pool.map(run, commands))
    assert sum(r.returncode == 0 for r in results) == successes, [r.stderr for r in results]
    for r in results:
        if r.returncode:
            assert error and error in r.stderr, r.stderr
    return results

def new_product(suffix):
    return int(scalar(f"INSERT INTO mm.produto(sku,nome,unidade,tipo,preco_venda) VALUES('{TAG}-{suffix}','Teste','UN','REVENDA',10) RETURNING id"))

def main():
    filial, fornecedor, cliente, parceiro, banco, tecnico, contrato = map(int, scalar("""
      SELECT f.id,fo.id,c.id,c.parceiro_id,b.id,r.id,sm.id
      FROM cad.filial f CROSS JOIN cad.fornecedor fo CROSS JOIN cad.cliente c
      CROSS JOIN fi.conta_bancaria b CROSS JOIN rh.colaborador r CROSS JOIN sm.contrato_manutencao sm
      WHERE f.nome='Fábrica Escola - Matriz' AND r.matricula='DEMO-002' LIMIT 1
    """).split('|'))
    depot = []
    for i in range(2):
        depot.append(int(scalar(f"INSERT INTO mm.deposito(filial_id,nome) VALUES({filial},'{TAG}-D{i}') RETURNING id")))
    product = new_product('STOCK')

    def buy(amount, d=0):
        cid = int(scalar(f"INSERT INTO mm.compra(fornecedor_id,deposito_id) VALUES({fornecedor},{depot[d]}) RETURNING id"))
        sql(f'INSERT INTO mm.compra_item(compra_id,produto_id,quantidade,custo_unitario) VALUES({cid},{product},{amount},1)')
        sql(f'SET ROLE erp_estoque; CALL mm.receber_compra({cid},CURRENT_DATE+30)')
        return cid

    buy(100)
    for repeat in range(3):
        # Duas transações tentam receber a mesma compra; apenas uma entrada é válida.
        cid = int(scalar(f'INSERT INTO mm.compra(fornecedor_id,deposito_id) VALUES({fornecedor},{depot[0]}) RETURNING id'))
        sql(f'INSERT INTO mm.compra_item(compra_id,produto_id,quantidade,custo_unitario) VALUES({cid},{product},1,1)')
        race([f'BEGIN; SET LOCAL ROLE erp_estoque; CALL mm.receber_compra({cid},CURRENT_DATE+30); SELECT pg_sleep(0.15); COMMIT;']*2,
             1, 'Compra já recebida')
        assert scalar(f"SELECT count(*) FROM mm.movimento WHERE origem='COMPRA:{cid}'") == '1'

        # Dois pagamentos distintos não podem ultrapassar o mesmo saldo.
        tid = int(scalar(f"INSERT INTO fi.titulo(filial_id,parceiro_id,tipo,descricao,vencimento,valor) VALUES({filial},{parceiro},'RECEBER','{TAG}',CURRENT_DATE+1,100) RETURNING id"))
        race([f"BEGIN; SET LOCAL ROLE erp_financeiro; CALL fi.baixar_titulo({tid},{banco},80,'{uuid.uuid4()}'); SELECT pg_sleep(0.15); COMMIT;" for _ in range(2)],
             1, 'Baixa excede saldo')
        assert Decimal(scalar(f'SELECT saldo FROM fi.v_titulos_abertos WHERE id={tid}')) == 20

        # Estruturas recíprocas: A usa B e B usa A não podem coexistir.
        pa, pb = new_product(f'BOM{repeat}A'), new_product(f'BOM{repeat}B')
        race([f'BEGIN; SET LOCAL ROLE erp_producao; INSERT INTO pp.bom(produto_id,componente_id,quantidade) VALUES({a},{b},1); SELECT pg_sleep(0.15); COMMIT;'
              for a, b in [(pa, pb), (pb, pa)]], 1, 'Estrutura de produto cíclica')
        assert scalar(f'SELECT count(*) FROM pp.bom WHERE produto_id IN ({pa},{pb})') == '1'

        # Duas reservas do mesmo técnico no mesmo horário: só uma é confirmada.
        osid = int(scalar(f"INSERT INTO sm.ordem_servico(contrato_id,descricao) VALUES({contrato},'{TAG}') RETURNING id"))
        day = 100 + repeat
        race([f"BEGIN; SET LOCAL ROLE erp_operacoes; INSERT INTO sm.agendamento(ordem_servico_id,tecnico_id,inicio,fim) VALUES({osid},{tecnico},CURRENT_DATE+interval '{day} days 8 hours',CURRENT_DATE+interval '{day} days 9 hours'); SELECT pg_sleep(0.15); COMMIT;"]*2,
             1, 'Técnico já agendado')
        assert scalar(f'SELECT count(*) FROM sm.agendamento WHERE ordem_servico_id={osid}') == '1'

        # Duas marcações sobrepostas de ponto também são serializadas.
        race([f"BEGIN; SET LOCAL ROLE erp_rh; INSERT INTO rh.ponto(colaborador_id,entrada,saida) VALUES({tecnico},CURRENT_DATE+interval '{day} days 10 hours',CURRENT_DATE+interval '{day} days 11 hours'); SELECT pg_sleep(0.15); COMMIT;"]*2,
             1, 'Intervalos de ponto sobrepostos')
        assert scalar(f"SELECT count(*) FROM rh.ponto WHERE colaborador_id={tecnico} AND entrada=CURRENT_DATE+interval '{day} days 10 hours'") == '1'

        # Duas depreciações da mesma competência não duplicam a quota.
        aid = int(scalar(f"INSERT INTO am.ativo(filial_id,patrimonio,descricao,aquisicao,valor_aquisicao,vida_util_meses) VALUES({filial},'{TAG}-A{repeat}','Teste',CURRENT_DATE,1000,3) RETURNING id"))
        race([f"BEGIN; SET LOCAL ROLE erp_operacoes; CALL am.depreciar({aid},date_trunc('month',CURRENT_DATE)::date); SELECT pg_sleep(0.15); COMMIT;"]*2,
             1, 'Competência deve ser')
        assert scalar(f'SELECT count(*) FROM am.depreciacao WHERE ativo_id={aid}') == '1'
        print(f'PASSOU: repetição {repeat+1}/3 de seis disputas concorrentes.')

    # Modelo independente, em Decimal: não calcula o saldo esperado consultando o banco.
    expected = [Decimal(103), Decimal(0)]
    rng = random.Random(20261111)
    accepted = rejected = 0
    for step in range(200):
        d = rng.randrange(2)
        quantity = Decimal(rng.randrange(1, 2500)) / 100
        action = rng.choice(['compra', 'venda', 'transferencia'])
        if action == 'compra':
            buy(quantity, d)
            expected[d] += quantity
            accepted += 1
        elif action == 'transferencia':
            result = sql(f'SET ROLE erp_estoque; CALL mm.transferir({product},{depot[d]},{depot[1-d]},{quantity})', ok=False)
            if quantity <= expected[d]:
                assert result.returncode == 0, result.stderr
                expected[d] -= quantity
                expected[1-d] += quantity
                accepted += 1
            else:
                assert result.returncode and 'Estoque insuficiente' in result.stderr, result.stderr
                rejected += 1
        else:
            oid = int(scalar(f'INSERT INTO sd.pedido(cliente_id,deposito_id) VALUES({cliente},{depot[d]}) RETURNING id'))
            sql(f'INSERT INTO sd.pedido_item(pedido_id,produto_id,quantidade,preco_unitario) VALUES({oid},{product},{quantity},10)')
            result = sql(f'SET ROLE erp_comercial; CALL sd.faturar_pedido({oid},CURRENT_DATE+10)', ok=False)
            if quantity <= expected[d]:
                assert result.returncode == 0, result.stderr
                expected[d] -= quantity
                accepted += 1
            else:
                assert result.returncode and 'Estoque insuficiente' in result.stderr, result.stderr
                assert scalar(f"SELECT count(*) FROM fi.titulo WHERE origem='PEDIDO:{oid}'") == '0'
                rejected += 1
        for i in range(2):
            actual = Decimal(scalar(f'SELECT coalesce((SELECT quantidade FROM mm.estoque WHERE produto_id={product} AND deposito_id={depot[i]}),0)'))
            assert actual == expected[i], (step, action, i, actual, expected[i])
    assert scalar(f"SELECT count(*) FROM mm.estoque e WHERE produto_id={product} AND quantidade<>(SELECT coalesce(sum(m.quantidade),0) FROM mm.movimento m WHERE m.produto_id=e.produto_id AND m.deposito_id=e.deposito_id)") == '0'
    print(f'PASSOU: 200 operações; {accepted} aceitas e {rejected} recusadas corretamente; 400 comparações de saldo.')

if __name__ == '__main__':
    main()
