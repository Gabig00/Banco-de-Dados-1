-- Testes adicionais da revisão. Requer instalação com V007 e dados fictícios.
\set ON_ERROR_STOP on
BEGIN;
CREATE TEMP TABLE resultados (teste text PRIMARY KEY);
CREATE FUNCTION pg_temp.verificar(p_condicao boolean,p_nome text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
 IF p_condicao IS DISTINCT FROM true THEN RAISE EXCEPTION 'FALHOU: %',p_nome; END IF;
 INSERT INTO resultados VALUES(p_nome);
END $$;
CREATE FUNCTION pg_temp.esperar_erro(p_sql text,p_estado text,p_nome text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE recebido text;
BEGIN
 BEGIN EXECUTE p_sql;
 EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS recebido=RETURNED_SQLSTATE;
 END;
 IF recebido IS DISTINCT FROM p_estado THEN RAISE EXCEPTION 'FALHOU: %; esperado SQLSTATE %, recebido %',p_nome,p_estado,recebido; END IF;
 INSERT INTO resultados VALUES(p_nome);
END $$;
-- Os testes de permissão precisam apenas registrar seu resultado na tabela temporária.
GRANT INSERT,SELECT ON resultados TO PUBLIC;


-- Regressões das falhas encontradas durante a revisão.
SELECT pg_temp.esperar_erro('INSERT INTO mm.produto(sku,nome,unidade,tipo,preco_venda) VALUES(''TEST-NAN'',''x'',''UN'',''ACABADO'',''NaN'')','23514','R01 - preço NaN rejeitado');
SELECT pg_temp.esperar_erro('UPDATE mm.estoque SET quantidade=''NaN''','23514','R02 - quantidade NaN rejeitada');
SELECT pg_temp.esperar_erro('UPDATE rh.colaborador SET salario_base=''NaN''','23514','R03 - salário NaN rejeitado');
SELECT pg_temp.esperar_erro('INSERT INTO api.telemetria(sensor_id,medido_em,valor) SELECT id,CURRENT_TIMESTAMP+interval ''1 day'',''Infinity'' FROM api.sensor','23514','R04 - telemetria infinita rejeitada');
SELECT pg_temp.esperar_erro('UPDATE sm.ordem_servico SET prazo_em=prazo_em+interval ''1 year''','P0001','R05 - prazo SLA congelado');
SELECT pg_temp.esperar_erro('UPDATE sm.ordem_servico SET aberta_em=aberta_em+interval ''1 hour''','P0001','R06 - abertura SLA congelada');
SELECT pg_temp.esperar_erro('UPDATE am.ativo SET valor_aquisicao=100','P0001','R07 - base depreciada não pode diminuir');
SELECT pg_temp.esperar_erro('UPDATE am.ativo SET vida_util_meses=1','P0001','R08 - vida útil congelada após primeira quota');
SELECT pg_temp.esperar_erro('UPDATE qm.plano_amostragem SET max_defeitos=5','P0001','R09 - critério de plano imutável');
SELECT pg_temp.esperar_erro('UPDATE qm.inspecao SET defeitos=0','P0001','R10 - inspeção permanece histórica');
SELECT pg_temp.esperar_erro('UPDATE ps.projeto SET fim_previsto=inicio+1','P0001','R11 - projeto não exclui tarefas do cronograma');
SELECT pg_temp.esperar_erro('UPDATE fi.conta_contabil SET sintetica=true WHERE codigo=''1.02''','P0001','R12 - conta analítica não vira sintética');

DO $$
#variable_conflict use_variable
DECLARE filial bigint; filial2 bigint; cli bigint; parceiro bigint; dep bigint; dep2 bigint; produto bigint;
 fornecedor bigint; compra bigint; pedido bigint; n integer; saldo numeric; l bigint; conta bigint;
 ativo bigint; c date; mes integer; a bigint; b bigint; qtd numeric; ct bigint; op bigint; bom bigint;
BEGIN
 SELECT id INTO filial FROM cad.filial LIMIT 1;
 INSERT INTO cad.filial(nome,cnpj) VALUES('Filial de teste','00000000009900') RETURNING id INTO filial2;
 SELECT id INTO dep FROM mm.deposito WHERE nome='Principal';
 INSERT INTO mm.deposito(filial_id,nome) VALUES(filial2,'Teste') RETURNING id INTO dep2;
 SELECT id INTO produto FROM mm.produto WHERE sku='PA-CADEIRA';
 SELECT id INTO cli FROM cad.cliente LIMIT 1;
 SELECT id INTO parceiro FROM cad.parceiro WHERE nome='Fornecedor Demonstração';
 SELECT id INTO fornecedor FROM cad.fornecedor LIMIT 1;
 PERFORM pg_temp.esperar_erro(format('UPDATE mm.deposito SET filial_id=%s WHERE id=%s',filial2,dep),'P0001','R13 - depósito não muda de filial');
 PERFORM pg_temp.esperar_erro(format('UPDATE cad.centro_custo SET filial_id=%s',filial2),'P0001','R14 - centro de custo não muda de filial');
 PERFORM pg_temp.esperar_erro(format('UPDATE cad.cliente SET parceiro_id=%s WHERE id=%s',parceiro,cli),'P0001','R15 - cliente não troca identidade do parceiro');
 PERFORM pg_temp.esperar_erro(format('CALL mm.transferir(%s,%s,%s,1)',produto,dep,dep2),'P0001','R16 - transferência entre filiais recusada');
 -- Uma compra começa a movimentar estoque, mas o vencimento inválido deve reverter tudo.
 INSERT INTO mm.compra(fornecedor_id,deposito_id) VALUES(fornecedor,dep) RETURNING id INTO compra;
 INSERT INTO mm.compra_item(compra_id,produto_id,quantidade,custo_unitario) VALUES(compra,produto,10,100);
 SELECT count(*) INTO n FROM mm.movimento;
 PERFORM pg_temp.esperar_erro(format('CALL mm.receber_compra(%s,CURRENT_DATE-1)',compra),'23514','R17 - vencimento de compra inválido rejeitado');
 PERFORM pg_temp.verificar((SELECT count(*) FROM mm.movimento)=n AND (SELECT status FROM mm.compra WHERE id=compra)='ABERTA','R18 - rollback da compra após movimentação');
 -- Venda com um item disponível e outro insuficiente deve reverter a primeira saída.
 INSERT INTO sd.pedido(cliente_id,deposito_id) VALUES(cli,dep) RETURNING id INTO pedido;
 INSERT INTO sd.pedido_item(pedido_id,produto_id,quantidade,preco_unitario)
 SELECT pedido,id,CASE sku WHEN 'MP-MADEIRA' THEN 1 ELSE 9999 END,10 FROM mm.produto WHERE sku IN ('MP-MADEIRA','MP-PARAFUSO');
 SELECT count(*) INTO n FROM mm.movimento;
 PERFORM pg_temp.esperar_erro(format('CALL sd.faturar_pedido(%s,CURRENT_DATE+1)',pedido),'P0001','R19 - falta no segundo item rejeita venda');
 PERFORM pg_temp.verificar((SELECT count(*) FROM mm.movimento)=n,'R20 - rollback da primeira saída quando segunda falha');
 -- Contabilidade manual: duas partidas não equilibradas não podem ser publicadas.
 INSERT INTO fi.lancamento(filial_id,historico) VALUES(filial,'Teste de equilíbrio') RETURNING id INTO l;
 SELECT id INTO conta FROM fi.conta_contabil WHERE codigo='1.01';
 INSERT INTO fi.partida(lancamento_id,conta_id,natureza,valor) VALUES(l,conta,'D',10),(l,conta,'C',9);
 PERFORM pg_temp.esperar_erro(format('CALL fi.contabilizar(%s)',l),'P0001','R21 - lançamento desequilibrado rejeitado');
 UPDATE fi.partida SET valor=10 WHERE lancamento_id=l AND natureza='C';
 CALL fi.contabilizar(l);
 PERFORM pg_temp.verificar((SELECT status FROM fi.lancamento WHERE id=l)='CONTABILIZADO','R22 - lançamento corrigido contabiliza');
 PERFORM pg_temp.esperar_erro(format('DELETE FROM fi.partida WHERE lancamento_id=%s',l),'P0001','R23 - partida contabilizada não é excluída');
 INSERT INTO fi.conta_contabil(codigo,nome,natureza,sintetica) VALUES('TEST-A','A','ATIVO',true) RETURNING id INTO a;
 INSERT INTO fi.conta_contabil(codigo,nome,natureza,sintetica,superior_id) VALUES('TEST-B','B','ATIVO',true,a) RETURNING id INTO b;
 PERFORM pg_temp.esperar_erro(format('UPDATE fi.conta_contabil SET superior_id=%s WHERE id=%s',b,a),'P0001','R24 - hierarquia de contas não aceita ciclo');
 -- Arredondamento: 1000 / 3 distribui 333,33 + 333,34 + 333,33, sem quarta quota.
 c:=date_trunc('month',CURRENT_DATE)::date;
 INSERT INTO am.ativo(filial_id,patrimonio,descricao,aquisicao,valor_aquisicao,vida_util_meses)
 VALUES(filial,'TEST-ROUND','Teste',c,1000,3) RETURNING id INTO ativo;
 FOR mes IN 0..2 LOOP CALL am.depreciar(ativo,(c+make_interval(months=>mes))::date); END LOOP;
 PERFORM pg_temp.verificar((SELECT sum(valor) FROM am.depreciacao WHERE ativo_id=ativo)=1000,'R25 - quotas completam a base em três meses');
 PERFORM pg_temp.verificar((SELECT valor FROM am.depreciacao WHERE ativo_id=ativo ORDER BY competencia DESC LIMIT 1)=333.33,'R26 - centavos distribuídos pelo alvo acumulado');
 PERFORM pg_temp.esperar_erro(format('CALL am.depreciar(%s,%L)',ativo,(c+interval '3 months')::date),'P0001','R27 - não cria quarta quota após vida útil');
 INSERT INTO am.ativo(filial_id,patrimonio,descricao,aquisicao,valor_aquisicao,vida_util_meses)
 VALUES(filial,'TEST-CENT','Teste centavo',c,0.01,3) RETURNING id INTO ativo;
 FOR mes IN 0..2 LOOP
   -- Ao atingir o valor total antes da última competência, não há nova quota a registrar.
   IF (SELECT coalesce(sum(valor),0) FROM am.depreciacao WHERE ativo_id=ativo)<0.01 THEN
     CALL am.depreciar(ativo,(c+make_interval(months=>mes))::date);
   END IF;
 END LOOP;
 PERFORM pg_temp.verificar((SELECT sum(valor) FROM am.depreciacao WHERE ativo_id=ativo)=0.01,'R28 - valor de um centavo não fica eternamente sem depreciação');
 -- Snapshot da BOM não deve mudar após editar a estrutura corrente.
 SELECT id INTO ct FROM pp.centro_trabalho LIMIT 1;
 op:=pp.abrir_ordem(produto,dep,ct,1,CURRENT_DATE,1);
 SELECT id,quantidade INTO bom,qtd FROM pp.bom WHERE produto_id=produto ORDER BY id LIMIT 1;
 UPDATE pp.bom SET quantidade=quantidade+1 WHERE id=bom;
 PERFORM pg_temp.verificar(EXISTS(SELECT 1 FROM pp.ordem_componente oc JOIN pp.bom b ON b.componente_id=oc.produto_id WHERE oc.ordem_id=op AND b.id=bom AND oc.quantidade=qtd),'R29 - ordem mantém snapshot da BOM');
 CALL pp.concluir_ordem(op);
 PERFORM pg_temp.esperar_erro(format('CALL pp.concluir_ordem(%s)',op),'P0001','R30 - produção não conclui duas vezes');
 PERFORM pg_temp.esperar_erro(format('SELECT pp.abrir_ordem(%s,%s,%s,0.0001,CURRENT_DATE,1)',produto,dep,ct),'P0001','R31 - quantidade menor que precisão rejeitada');
END $$;

-- Testa ações positivas reais de todos os grupos, além de acesso negado.
SET LOCAL ROLE erp_estoque;
DO $$
DECLARE c bigint; i bigint; dep bigint; p bigint;
BEGIN
 SELECT id INTO dep FROM mm.deposito WHERE nome='Principal';
 SELECT id INTO p FROM mm.produto WHERE sku='PA-CADEIRA';
 INSERT INTO mm.compra(fornecedor_id,deposito_id) SELECT id,dep FROM cad.fornecedor LIMIT 1 RETURNING id INTO c;
 INSERT INTO mm.compra_item(compra_id,produto_id,quantidade,custo_unitario) VALUES(c,p,2,10);
 CALL mm.receber_compra(c,CURRENT_DATE+1);
 PERFORM pg_temp.verificar((SELECT status FROM mm.compra WHERE id=c)='RECEBIDA','R32 - estoque recebe compra válida com seu perfil');
 INSERT INTO mm.inventario(deposito_id) VALUES(dep) RETURNING id INTO i;
 INSERT INTO mm.inventario_item(inventario_id,produto_id,quantidade_contada) VALUES(i,p,10);
 CALL mm.aplicar_inventario(i);
 PERFORM pg_temp.verificar((SELECT quantidade FROM mm.estoque WHERE produto_id=p AND deposito_id=dep)=10,'R33 - inventário aplica ajuste com perfil de estoque');
END $$;
SELECT pg_temp.esperar_erro('TRUNCATE mm.movimento','42501','R34 - estoque não usa truncate no histórico');
RESET ROLE;
SET LOCAL ROLE erp_rh;
DO $$
DECLARE f bigint; c bigint;
BEGIN
 INSERT INTO rh.folha(filial_id,competencia) SELECT id,(date_trunc('month',CURRENT_DATE)+interval '1 month')::date FROM cad.filial WHERE nome='Fábrica Escola - Matriz' RETURNING id INTO f;
 SELECT id INTO c FROM rh.colaborador WHERE matricula='DEMO-001';
 INSERT INTO rh.folha_item(folha_id,colaborador_id,rubrica_id,valor) SELECT f,c,id,100 FROM rh.rubrica WHERE codigo='SALARIO';
 CALL rh.fechar_folha(f);
 PERFORM pg_temp.verificar((SELECT status FROM rh.folha WHERE id=f)='FECHADA','R35 - RH fecha folha por seu perfil');
 INSERT INTO rh.dado_sensivel(colaborador_id,conteudo_cifrado,versao_chave)
 VALUES(c,rh.cifrar('fictício','chave-teste-nao-utilizar-em-producao-123'),'teste');
 PERFORM pg_temp.verificar((SELECT rh.decifrar(conteudo_cifrado,'chave-teste-nao-utilizar-em-producao-123') FROM rh.dado_sensivel WHERE colaborador_id=c)='fictício','R36 - RH persiste e recupera conteúdo cifrado');
END $$;
RESET ROLE;
SET LOCAL ROLE erp_operacoes;
SELECT pg_temp.esperar_erro('UPDATE rh.colaborador SET nome=''intruso''','42501','R37 - operações não pode editar colaboradores');
DO $$
DECLARE serv bigint; tecnico bigint; t bigint; a bigint;
BEGIN
 INSERT INTO sm.ordem_servico(contrato_id,descricao) SELECT id,'Atendimento de teste' FROM sm.contrato_manutencao LIMIT 1 RETURNING id INTO serv;
 SELECT id INTO tecnico FROM rh.colaborador WHERE matricula='DEMO-002';
 INSERT INTO sm.agendamento(ordem_servico_id,tecnico_id,inicio,fim)
 VALUES(serv,tecnico,CURRENT_DATE+interval '10 days 8 hours',CURRENT_DATE+interval '10 days 9 hours');
 UPDATE sm.ordem_servico SET status='EM_ATENDIMENTO' WHERE id=serv;
 UPDATE sm.ordem_servico SET status='CONCLUIDA',concluida_em=CURRENT_TIMESTAMP WHERE id=serv;
 PERFORM pg_temp.verificar((SELECT status FROM sm.ordem_servico WHERE id=serv)='CONCLUIDA','R38 - operações agenda e encerra atendimento sem DML de RH');
 PERFORM pg_temp.esperar_erro(format('UPDATE sm.ordem_servico SET status=''ABERTA'',concluida_em=NULL WHERE id=%s',serv),'P0001','R39 - atendimento concluído não reabre');
 SELECT id INTO a FROM am.ativo WHERE patrimonio='DEMO-AT001';
 CALL am.depreciar(a,(date_trunc('month',CURRENT_DATE)+interval '1 month')::date);
 PERFORM pg_temp.verificar((SELECT count(*) FROM am.depreciacao WHERE ativo_id=a)=2,'R40 - operações executa depreciação autorizada');
END $$;
RESET ROLE;
SET LOCAL ROLE erp_producao;
DO $$
DECLARE o bigint; p bigint; d bigint; c bigint;
BEGIN
 SELECT id INTO p FROM mm.produto WHERE sku='PA-CADEIRA';
 SELECT id INTO d FROM mm.deposito WHERE nome='Principal';
 SELECT id INTO c FROM pp.centro_trabalho LIMIT 1;
 o:=pp.abrir_ordem(p,d,c,1,CURRENT_DATE,1);
 CALL pp.concluir_ordem(o);
 PERFORM pg_temp.verificar((SELECT status FROM pp.ordem WHERE id=o)='CONCLUIDA','R41 - produção abre e conclui ordem com seu perfil');
END $$;
SELECT pg_temp.esperar_erro('SELECT salario_base FROM rh.colaborador','42501','R42 - produção não consulta salários');
RESET ROLE;
SET LOCAL ROLE erp_integracao;
INSERT INTO api.inbox(conector_id,chave_externa,payload) SELECT id,'teste-integracao','{}' FROM api.conector LIMIT 1;
SELECT pg_temp.verificar(EXISTS(SELECT 1 FROM api.inbox WHERE chave_externa='teste-integracao'),'R43 - integração registra inbox');
SELECT pg_temp.esperar_erro('INSERT INTO api.inbox(conector_id,chave_externa,payload) SELECT id,''teste-integracao'',''{}'' FROM api.conector LIMIT 1','23505','R44 - inbox deduplica chave externa');
UPDATE api.outbox SET publicado_em=CURRENT_TIMESTAMP,tentativas=tentativas+1 WHERE tipo='pedido.faturado';
SELECT pg_temp.verificar(EXISTS(SELECT 1 FROM api.outbox WHERE tipo='pedido.faturado' AND publicado_em IS NOT NULL),'R45 - worker pode confirmar publicação');
SELECT pg_temp.esperar_erro('UPDATE api.outbox SET payload=''{}''','42501','R46 - worker não pode adulterar payload');
RESET ROLE;
SET LOCAL ROLE erp_bi;
CALL bi.atualizar_indicadores();
SELECT pg_temp.verificar((SELECT count(*) FROM bi.fato_venda)>=1,'R47 - BI executa carga com seu perfil');
SELECT pg_temp.esperar_erro('UPDATE bi.fato_venda SET valor=0','42501','R48 - BI não pode adulterar fatos');
RESET ROLE;
SET LOCAL ROLE erp_ceo;
SELECT pg_temp.verificar((SELECT count(*) FROM rh.dado_sensivel)=1,'R49 - CEO consulta tabela restrita');
SELECT pg_temp.esperar_erro('DELETE FROM grc.evento_auditoria','42501','R50 - CEO não apaga trilha');
SELECT pg_temp.esperar_erro('CREATE TABLE sys.teste_intrusao(id int)','42501','R51 - CEO não executa DDL administrativo');
RESET ROLE;
SET LOCAL ROLE erp_dba;
CREATE TABLE sys.teste_dba(id int);
DROP TABLE sys.teste_dba;
SELECT pg_temp.verificar(true,'R52 - DBA administra objetos');
RESET ROLE;
-- A integridade numérica deve cobrir cada coluna NUMERIC, não só as testadas acima.
SELECT pg_temp.verificar(NOT EXISTS(
 SELECT 1 FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE c.relkind IN ('r','p') AND NOT c.relispartition AND a.atttypid='numeric'::regtype AND a.attnum>0
 AND n.nspname IN ('cad','sys','fi','rh','mm','sd','pp','ps','sm','bi','grc','qm','am','fiscal','portal','api')
 AND NOT EXISTS(SELECT 1 FROM pg_constraint ck WHERE ck.conrelid=c.oid AND ck.conname='finito_'||a.attname)
),'R53 - todas as colunas NUMERIC rejeitam números especiais');
SELECT pg_temp.verificar(NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
 WHERE n.nspname IN ('cad','sys','fi','rh','mm','sd','pp','ps','sm','bi','grc','qm','am','fiscal','portal','api')
 AND a.grantee=0 AND a.privilege_type='EXECUTE'),'R54 - nenhuma rotina do ERP executável por PUBLIC');
SELECT pg_temp.verificar(NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname IN ('cad','sys','fi','rh','mm','sd','pp','ps','sm','bi','grc','qm','am','fiscal','portal','api')
 AND p.prosecdef AND NOT ('search_path=pg_catalog'=ANY(coalesce(p.proconfig,ARRAY[]::text[])))),'R55 - SECURITY DEFINER tem search_path fixo');
SELECT pg_temp.verificar(NOT EXISTS(SELECT 1 FROM mm.estoque e WHERE e.quantidade<>(SELECT coalesce(sum(m.quantidade),0) FROM mm.movimento m WHERE m.produto_id=e.produto_id AND m.deposito_id=e.deposito_id)),'R56 - estoque reconcilia com movimentos após bateria ampliada');
SELECT count(*) AS testes_revisao_aprovados FROM resultados;
SELECT teste FROM resultados ORDER BY teste;
ROLLBACK;
