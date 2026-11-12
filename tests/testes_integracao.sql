-- Execute depois de instalar.sql e dados_demonstracao.sql, como administrador.
-- Todas as alterações são revertidas. Sequências podem avançar mesmo com ROLLBACK.
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

SELECT pg_temp.verificar((SELECT count(*) FROM pg_namespace WHERE nspname IN ('cad','sys','fi','rh','mm','sd','pp','ps','sm','bi','grc','qm','am','fiscal','portal','api'))=16,'01 - schemas de todos os módulos');
SELECT pg_temp.verificar((SELECT quantidade FROM mm.v_estoque WHERE sku='MP-MADEIRA' AND deposito='Principal')=80,'02 - consumo de madeira na produção');
SELECT pg_temp.verificar((SELECT quantidade FROM mm.v_estoque WHERE sku='MP-PARAFUSO' AND deposito='Principal')=360,'03 - consumo de parafusos');
SELECT pg_temp.verificar((SELECT quantidade FROM mm.v_estoque WHERE sku='PA-CADEIRA' AND deposito='Principal')=5,'04 - produção, venda e transferência integradas');
SELECT pg_temp.verificar((SELECT quantidade FROM mm.v_estoque WHERE sku='PA-CADEIRA' AND deposito='Expedição')=2,'05 - entrada no destino da transferência');
SELECT pg_temp.verificar((SELECT saldo FROM fi.v_titulos_abertos WHERE tipo='RECEBER')=250,'06 - saldo após baixa parcial');
SELECT pg_temp.verificar((SELECT valor FROM fi.titulo WHERE tipo='PAGAR')=1200,'07 - contas a pagar da compra');
SELECT pg_temp.verificar(NOT EXISTS(SELECT 1 FROM fi.partida GROUP BY lancamento_id HAVING sum(CASE natureza WHEN 'D' THEN valor ELSE -valor END)<>0),'08 - partidas dobradas equilibradas');
SELECT pg_temp.verificar((SELECT liquido FROM rh.v_folha_resumo)=3600,'09 - folha líquida');
SELECT pg_temp.verificar((SELECT receita FROM bi.mv_receita_mensal)=450,'10 - BI consolida receita');
SELECT pg_temp.verificar((SELECT valor_contabil FROM am.v_valor_contabil)=11800,'11 - depreciação linear');
SELECT pg_temp.verificar((SELECT resultado FROM qm.inspecao)='REPROVADO','12 - qualidade calcula reprovação');
SELECT pg_temp.verificar((SELECT custo_realizado FROM ps.v_indicadores)=200,'13 - custo real de projeto sem multiplicação de joins');
SELECT pg_temp.verificar((SELECT prazo_em-aberta_em FROM sm.ordem_servico)=interval '24 hours','14 - SLA calculado na abertura');
SELECT pg_temp.verificar((SELECT count(*) FROM grc.evento_auditoria)>50,'15 - auditoria captura operações');
SELECT pg_temp.verificar((SELECT count(*) FROM api.outbox WHERE tipo='pedido.faturado')=1,'16 - outbox da venda');
SELECT pg_temp.verificar(NOT EXISTS(SELECT 1 FROM mm.estoque e WHERE e.quantidade<>(SELECT coalesce(sum(m.quantidade),0) FROM mm.movimento m WHERE m.produto_id=e.produto_id AND m.deposito_id=e.deposito_id)),'17 - saldo confere com razão de estoque');
CALL bi.atualizar_indicadores();
SELECT pg_temp.verificar((SELECT count(*) FROM bi.fato_venda)=1,'18 - carga DW idempotente');

DO $$
#variable_conflict use_variable
DECLARE p bigint; dep bigint; cli bigint; banco bigint; titulo bigint; pedido bigint; n integer; antes numeric; lote bigint;
BEGIN
 SELECT id INTO p FROM mm.produto WHERE sku='PA-CADEIRA';
 SELECT id INTO dep FROM mm.deposito WHERE nome='Principal';
 SELECT id INTO cli FROM cad.cliente;
 SELECT id INTO banco FROM fi.conta_bancaria;
 SELECT id INTO titulo FROM fi.titulo WHERE tipo='RECEBER';
 PERFORM pg_temp.esperar_erro(format('CALL fi.baixar_titulo(%s,%s,251,%L)',titulo,banco,'22222222-2222-4222-8222-222222222222'),'P0001','19 - impede pagamento acima do saldo');
 CALL fi.baixar_titulo(titulo,banco,200,'11111111-1111-4111-8111-111111111111');
 PERFORM pg_temp.verificar((SELECT count(*) FROM fi.baixa)=1,'20 - repetição idêntica de baixa não duplica');
 PERFORM pg_temp.esperar_erro(format('CALL fi.baixar_titulo(%s,%s,199,%L)',titulo,banco,'11111111-1111-4111-8111-111111111111'),'P0001','21 - rejeita chave idempotente com outro valor');
 SELECT id INTO pedido FROM sd.pedido WHERE status='FATURADO';
 PERFORM pg_temp.esperar_erro(format('CALL sd.faturar_pedido(%s,CURRENT_DATE+10)',pedido),'P0001','22 - impede faturamento duplicado');
 PERFORM pg_temp.esperar_erro(format('UPDATE sd.pedido_item SET quantidade=4 WHERE pedido_id=%s',pedido),'P0001','23 - itens faturados imutáveis');
 PERFORM pg_temp.esperar_erro(format('UPDATE sd.pedido SET status=''ABERTO'' WHERE id=%s',pedido),'P0001','24 - documento não pode ser reaberto');
 INSERT INTO sd.pedido(cliente_id,deposito_id) VALUES(cli,dep) RETURNING id INTO pedido;
 INSERT INTO sd.pedido_item(pedido_id,produto_id,quantidade,preco_unitario) VALUES(pedido,p,9999,150);
 SELECT count(*) INTO n FROM fi.titulo;
 PERFORM pg_temp.esperar_erro(format('CALL sd.faturar_pedido(%s,CURRENT_DATE+10)',pedido),'P0001','25 - rejeita venda sem estoque');
 PERFORM pg_temp.verificar((SELECT count(*) FROM fi.titulo)=n AND (SELECT status FROM sd.pedido WHERE id=pedido)='ABERTO','26 - falha de venda reverte todos os efeitos');
 PERFORM pg_temp.esperar_erro('UPDATE mm.movimento SET quantidade=999','P0001','27 - razão de estoque imutável');
 PERFORM pg_temp.esperar_erro('DELETE FROM grc.evento_auditoria','P0001','28 - trilha de auditoria imutável por DML');
 PERFORM pg_temp.esperar_erro('INSERT INTO mm.produto(sku,nome,unidade,tipo,preco_venda) VALUES(''PA-CADEIRA'',''x'',''UN'',''ACABADO'',1)','23505','29 - SKU único');
 PERFORM pg_temp.esperar_erro('INSERT INTO cad.cliente(parceiro_id) VALUES(-999)','23503','30 - integridade referencial');
 PERFORM pg_temp.esperar_erro('INSERT INTO mm.produto(sku,nome,unidade,tipo,preco_venda) VALUES(''NEGATIVO'',''x'',''UN'',''ACABADO'',-1)','23514','31 - valor negativo rejeitado');
 SELECT quantidade INTO antes FROM mm.estoque WHERE produto_id=p AND deposito_id=dep;
 PERFORM pg_temp.esperar_erro(format('CALL mm.transferir(%s,%s,%s,9999)',p,dep,(SELECT id FROM mm.deposito WHERE nome='Expedição')),'P0001','32 - transferência sem estoque não produz saldo parcial');
 PERFORM pg_temp.verificar((SELECT quantidade FROM mm.estoque WHERE produto_id=p AND deposito_id=dep)=antes,'33 - saldo preservado após transferência rejeitada');
 PERFORM pg_temp.esperar_erro(format('INSERT INTO pp.bom(produto_id,componente_id,quantidade) VALUES(%s,%s,1)',(SELECT id FROM mm.produto WHERE sku='MP-MADEIRA'),p),'P0001','34 - BOM não aceita ciclo indireto');
 PERFORM pg_temp.esperar_erro('UPDATE rh.folha_item SET valor=1','P0001','35 - folha fechada protegida');
 PERFORM pg_temp.esperar_erro('INSERT INTO rh.ponto(colaborador_id,entrada,saida) SELECT colaborador_id,entrada,saida-interval ''1 minute'' FROM rh.ponto LIMIT 1','P0001','36 - ponto não aceita sobreposição');
 PERFORM pg_temp.esperar_erro('INSERT INTO sm.agendamento(ordem_servico_id,tecnico_id,inicio,fim) SELECT ordem_servico_id,tecnico_id,inicio+interval ''5 minutes'',fim FROM sm.agendamento LIMIT 1','P0001','37 - agenda não aceita sobreposição');
 PERFORM pg_temp.verificar(rh.decifrar(rh.cifrar('dado fictício','chave-exclusiva-de-teste-com-mais-de-32-caracteres'),'chave-exclusiva-de-teste-com-mais-de-32-caracteres')='dado fictício','38 - cifra AES256 recupera conteúdo com chave correta');
 PERFORM pg_temp.esperar_erro('SELECT rh.cifrar(''dado'',''curta'')','P0001','39 - chave curta rejeitada');
 PERFORM pg_temp.esperar_erro(format('CALL am.depreciar(%s,date_trunc(''month'',CURRENT_DATE)::date)',(SELECT id FROM am.ativo)),'P0001','40 - não duplica depreciação mensal');
 INSERT INTO api.telemetria(sensor_id,medido_em,valor) SELECT id,'2040-01-01 00:00:00+00',10 FROM api.sensor;
 PERFORM pg_temp.verificar(EXISTS(SELECT 1 FROM api.telemetria_demais WHERE medido_em='2040-01-01 00:00:00+00'),'41 - partição default recebe data futura');
END $$;

-- Permissões verificadas sob os próprios grupos de acesso, não apenas por catálogo.
SET LOCAL ROLE erp_comercial;
SELECT pg_temp.esperar_erro('SELECT salario_base FROM rh.colaborador','42501','42 - comercial não acessa salários');
SELECT pg_temp.esperar_erro('UPDATE mm.estoque SET quantidade=1000','42501','43 - comercial não manipula estoque diretamente');
SELECT pg_temp.esperar_erro('SELECT fi.registrar_dupla(1,''1.01'',''3.01'',1,''indevido'',''indevido'')','42501','44 - helper contábil privado');
SELECT pg_temp.esperar_erro('INSERT INTO sd.pedido(cliente_id,deposito_id,status) SELECT c.id,d.id,''FATURADO'' FROM cad.cliente c CROSS JOIN mm.deposito d LIMIT 1','42501','45 - não permite inserir pedido já faturado');
DO $$
#variable_conflict use_variable
DECLARE p bigint;
BEGIN
 INSERT INTO sd.pedido(cliente_id,deposito_id) SELECT c.id,d.id FROM cad.cliente c CROSS JOIN mm.deposito d WHERE d.nome='Principal' LIMIT 1 RETURNING id INTO p;
 INSERT INTO sd.pedido_item(pedido_id,produto_id,quantidade,preco_unitario) SELECT p,id,1,150 FROM mm.produto WHERE sku='PA-CADEIRA';
 CALL sd.faturar_pedido(p,CURRENT_DATE+10);
 PERFORM pg_temp.verificar((SELECT status FROM sd.pedido WHERE id=p)='FATURADO','46 - comercial fatura por procedure sem DML financeiro');
END $$;
RESET ROLE;
SET LOCAL ROLE erp_diretor;
SELECT pg_temp.verificar((SELECT sum(receita) FROM bi.v_vendas_mensais)=450,'47 - diretor consulta BI');
SELECT pg_temp.esperar_erro('SELECT * FROM rh.dado_sensivel','42501','48 - diretor não lê dados pessoais cifrados');
RESET ROLE;
SET LOCAL ROLE erp_auditor;
SELECT pg_temp.esperar_erro('INSERT INTO grc.evento_auditoria(usuario_banco,papel_ativo,tabela,operacao,campos,transacao) VALUES(current_user,current_user,''x'',''x'',ARRAY[]::text[],1)','42501','49 - auditor não forja trilha');
SELECT pg_temp.esperar_erro('TRUNCATE grc.evento_auditoria','42501','50 - auditor não apaga trilha por truncate');
RESET ROLE;
SET LOCAL ROLE erp_rh;
SELECT pg_temp.verificar((SELECT count(*) FROM rh.colaborador)=2,'51 - RH consulta colaboradores');
SELECT pg_temp.verificar(rh.decifrar(rh.cifrar('exemplo','chave-exclusiva-de-teste-com-mais-de-32-caracteres'),'chave-exclusiva-de-teste-com-mais-de-32-caracteres')='exemplo','52 - RH autorizado a cifrar e decifrar');
RESET ROLE;
SET LOCAL ROLE erp_financeiro;
DO $$
#variable_conflict use_variable
DECLARE t bigint; b bigint;
BEGIN
 SELECT id INTO t FROM fi.titulo WHERE origem LIKE 'PEDIDO:%' AND valor=450;
 SELECT id INTO b FROM fi.conta_bancaria;
 CALL fi.baixar_titulo(t,b,250,'33333333-3333-4333-8333-333333333333');
 PERFORM pg_temp.verificar((SELECT saldo FROM fi.v_titulos_abertos WHERE id=t)=0,'53 - financeiro liquida saldo restante');
END $$;
RESET ROLE;
SET LOCAL ROLE erp_estoque;
DO $$
#variable_conflict use_variable
DECLARE c bigint;
BEGIN
 SELECT id INTO c FROM mm.compra LIMIT 1;
 PERFORM pg_temp.esperar_erro(format('CALL mm.receber_compra(%s,CURRENT_DATE+30)',c),'P0001','54 - estoque não recebe compra duas vezes');
END $$;
RESET ROLE;
SELECT pg_temp.verificar(NOT EXISTS(SELECT 1 FROM mm.estoque WHERE quantidade<0),'55 - nenhum saldo negativo após fluxos');
SELECT pg_temp.verificar((SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('mm','fi','sd','pp','rh','bi','am') AND p.prokind='p')>=10,'56 - procedures operacionais instaladas');
SELECT count(*) AS testes_aprovados FROM resultados;
SELECT teste FROM resultados ORDER BY teste;
ROLLBACK;
