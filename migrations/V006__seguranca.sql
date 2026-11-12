-- V006: RBAC real no PostgreSQL. Papéis NOLOGIN não possuem senhas embutidas.
-- Execute a instalação como superusuário em instância de desenvolvimento dedicada.
-- Para uso real, o DBA cria logins individuais e concede apenas o grupo necessário.
-- Ex.: CREATE ROLE ana LOGIN; GRANT erp_financeiro TO ana;
-- Defina a senha fora deste arquivo, por exemplo com \password ana no psql.
-- Portal/mobile não recebe um login com leitura geral: a API implementará autorização
-- por identidade autenticada. Esta versão NÃO oferece isolamento multiempresa/RLS.
DO $$
DECLARE papel text;
BEGIN
 FOREACH papel IN ARRAY ARRAY['erp_dba','erp_ceo','erp_diretor','erp_financeiro','erp_rh',
 'erp_estoque','erp_comercial','erp_producao','erp_operacoes','erp_auditor','erp_bi','erp_integracao'] LOOP
   IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=papel) THEN EXECUTE format('CREATE ROLE %I NOLOGIN',papel); END IF;
 END LOOP;
END $$;

-- Funções são executáveis por PUBLIC por padrão; revogamos isso explicitamente.
DO $$
DECLARE s text;
BEGIN
 FOREACH s IN ARRAY ARRAY['cad','sys','fi','rh','mm','sd','pp','ps','sm','bi','grc','qm','am','fiscal','portal','api','extensoes'] LOOP
   EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC',s);
   EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM PUBLIC',s);
   EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA %I FROM PUBLIC',s);
   EXECUTE format('REVOKE ALL ON ALL ROUTINES IN SCHEMA %I FROM PUBLIC',s);
   EXECUTE format('GRANT USAGE ON SCHEMA %I TO erp_ceo,erp_diretor,erp_dba',s);
   EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO erp_ceo',s);
   EXECUTE format('GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA %I TO erp_ceo',s);
 END LOOP;
END $$;

GRANT USAGE ON SCHEMA cad,fi TO erp_financeiro;
GRANT USAGE ON SCHEMA cad,rh,extensoes,sys TO erp_rh;
GRANT USAGE ON SCHEMA cad,mm TO erp_estoque;
GRANT USAGE ON SCHEMA cad,mm,sd,fiscal TO erp_comercial;
GRANT USAGE ON SCHEMA cad,mm,pp,rh TO erp_producao;
GRANT USAGE ON SCHEMA cad,ps,sm,am,qm,rh,mm,pp TO erp_operacoes;
GRANT USAGE ON SCHEMA grc,fi,fiscal TO erp_auditor;
GRANT USAGE ON SCHEMA bi TO erp_bi;
GRANT USAGE ON SCHEMA api TO erp_integracao;
GRANT SELECT ON ALL TABLES IN SCHEMA cad TO erp_financeiro,erp_rh,erp_estoque,erp_comercial,erp_producao,erp_operacoes;
GRANT SELECT ON ALL TABLES IN SCHEMA fi TO erp_financeiro,erp_auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA mm TO erp_estoque,erp_comercial,erp_producao,erp_operacoes;
GRANT SELECT ON ALL TABLES IN SCHEMA sd TO erp_comercial;
GRANT SELECT ON ALL TABLES IN SCHEMA fiscal TO erp_comercial,erp_auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA rh TO erp_rh;
GRANT SELECT ON ALL TABLES IN SCHEMA pp TO erp_producao,erp_operacoes;
GRANT SELECT ON ALL TABLES IN SCHEMA ps,sm,am,qm TO erp_operacoes;
GRANT SELECT ON ALL TABLES IN SCHEMA grc TO erp_auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA bi TO erp_bi,erp_diretor;
GRANT SELECT ON fi.v_fluxo_caixa,fi.v_balancete,fi.v_orcamento_realizado,mm.v_estoque,
 ps.v_indicadores,sm.v_sla,am.v_valor_contabil,grc.v_riscos,fiscal.v_livro_saida TO erp_diretor;

-- Acesso operacional ao colaborador sem expor salário ou conteúdo cifrado.
GRANT SELECT(id,nome,matricula,filial_id) ON rh.colaborador TO erp_producao,erp_operacoes;
-- Triggers de agenda precisam bloquear a linha, mas nunca alterar salários.
GRANT UPDATE(nome) ON rh.colaborador TO erp_operacoes;
GRANT SELECT ON sys.usuario TO erp_rh;
GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA fi TO erp_financeiro;
GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA rh TO erp_rh;
GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA mm TO erp_estoque;
GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA sd,cad TO erp_comercial;
GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA pp TO erp_producao;
GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA ps,sm,am,qm TO erp_operacoes;
GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA api TO erp_integracao;

-- CRUD somente em tabelas de entrada; saldos e documentos derivados ficam protegidos.
GRANT INSERT,UPDATE,DELETE ON fi.orcamento,fi.conciliacao TO erp_financeiro;
GRANT INSERT ON fi.extrato,fi.titulo,fi.partida TO erp_financeiro;
GRANT INSERT(filial_id,data,historico,origem) ON fi.lancamento TO erp_financeiro;
GRANT UPDATE(historico) ON fi.lancamento TO erp_financeiro;
GRANT UPDATE,DELETE ON fi.partida TO erp_financeiro;
GRANT INSERT,UPDATE,DELETE ON rh.cargo,rh.colaborador,rh.dado_sensivel,rh.beneficio,
 rh.colaborador_beneficio,rh.ponto,rh.folha_item,rh.vaga,rh.candidatura,rh.avaliacao TO erp_rh;
GRANT INSERT(filial_id,competencia) ON rh.folha TO erp_rh;
GRANT UPDATE(competencia) ON rh.folha TO erp_rh;
GRANT INSERT,UPDATE,DELETE ON mm.compra_item,mm.inventario_item TO erp_estoque;
GRANT INSERT(fornecedor_id,deposito_id,criada_em) ON mm.compra TO erp_estoque;
GRANT INSERT(deposito_id,data) ON mm.inventario TO erp_estoque;
GRANT UPDATE(criada_em) ON mm.compra TO erp_estoque;
GRANT UPDATE(data) ON mm.inventario TO erp_estoque;
GRANT INSERT,UPDATE,DELETE ON cad.parceiro,cad.cliente,sd.oportunidade,sd.interacao,sd.contrato,sd.pedido_item TO erp_comercial;
GRANT INSERT(cliente_id,deposito_id,contrato_id,criado_em) ON sd.pedido TO erp_comercial;
GRANT UPDATE(contrato_id,criado_em) ON sd.pedido TO erp_comercial;
GRANT INSERT,UPDATE,DELETE ON pp.bom,pp.apontamento TO erp_producao;
GRANT INSERT,UPDATE,DELETE ON ps.projeto,ps.tarefa,ps.alocacao,ps.apontamento,
 sm.contrato_manutencao,sm.ordem_servico,sm.agendamento,am.ativo,am.reavaliacao,am.manutencao,
 qm.plano_amostragem,qm.lote,qm.inspecao,qm.nao_conformidade TO erp_operacoes;
GRANT SELECT,INSERT ON api.inbox,api.telemetria,api.previsao_demanda,api.ancora_blockchain TO erp_integracao;
GRANT SELECT ON api.conector,api.sensor,api.outbox TO erp_integracao;
GRANT UPDATE(publicado_em,tentativas) ON api.outbox TO erp_integracao;
GRANT UPDATE(processado_em) ON api.inbox TO erp_integracao;

GRANT EXECUTE ON PROCEDURE mm.receber_compra(bigint,date),mm.aplicar_inventario(bigint),mm.transferir(bigint,bigint,bigint,numeric) TO erp_estoque,erp_ceo;
GRANT EXECUTE ON PROCEDURE sd.faturar_pedido(bigint,date) TO erp_comercial,erp_ceo;
GRANT EXECUTE ON PROCEDURE fi.baixar_titulo(bigint,bigint,numeric,uuid),fi.contabilizar(bigint) TO erp_financeiro,erp_ceo;
GRANT EXECUTE ON FUNCTION pp.abrir_ordem(bigint,bigint,bigint,numeric,date,numeric) TO erp_producao,erp_ceo;
GRANT EXECUTE ON PROCEDURE pp.concluir_ordem(bigint) TO erp_producao,erp_ceo;
GRANT EXECUTE ON PROCEDURE rh.fechar_folha(bigint) TO erp_rh,erp_ceo;
GRANT EXECUTE ON FUNCTION rh.cifrar(text,text),rh.decifrar(bytea,text) TO erp_rh,erp_ceo;
GRANT EXECUTE ON FUNCTION extensoes.pgp_sym_encrypt(text,text,text),extensoes.pgp_sym_decrypt(bytea,text) TO erp_rh,erp_ceo;
GRANT EXECUTE ON PROCEDURE am.depreciar(bigint,date) TO erp_operacoes,erp_ceo;
GRANT EXECUTE ON PROCEDURE bi.carregar_dw(),bi.atualizar_indicadores() TO erp_bi,erp_ceo;

-- CEO agrega grupos de negócio e pode consultar todas as áreas, sem ser superusuário.
-- Diretor recebe relatórios, não salários nem documentos pessoais.
GRANT erp_financeiro,erp_rh,erp_estoque,erp_comercial,erp_producao,erp_operacoes,erp_bi,erp_integracao TO erp_ceo;

-- DBA torna-se proprietário dos objetos do projeto, não de outros bancos/esquemas.
-- O instalador precisa de SUPERUSER para a troca de proprietário das rotinas de extensão.
DO $$
DECLARE r record; s text;
BEGIN
 FOREACH s IN ARRAY ARRAY['cad','sys','fi','rh','mm','sd','pp','ps','sm','bi','grc','qm','am','fiscal','portal','api','extensoes'] LOOP
   EXECUTE format('ALTER SCHEMA %I OWNER TO erp_dba',s);
 END LOOP;
 FOR r IN SELECT n.nspname,c.relname,c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname=ANY(ARRAY['cad','sys','fi','rh','mm','sd','pp','ps','sm','bi','grc','qm','am','fiscal','portal','api'])
 AND c.relkind IN ('r','p','v','m') LOOP
   EXECUTE format('ALTER %s %I.%I OWNER TO erp_dba',CASE r.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END,r.nspname,r.relname);
 END LOOP;
 -- Sequências de identidade acompanham as tabelas; esta é a sequência independente.
 ALTER SEQUENCE fiscal.numero_documento_seq OWNER TO erp_dba;
 FOR r IN SELECT p.oid::regprocedure rotina,p.prokind FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname=ANY(ARRAY['cad','sys','fi','rh','mm','sd','pp','ps','sm','bi','grc','qm','am','fiscal','portal','api']) LOOP
   EXECUTE format('ALTER %s %s OWNER TO erp_dba',CASE r.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,r.rotina);
 END LOOP;
END $$;
GRANT USAGE ON SCHEMA extensoes TO erp_dba;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensoes TO erp_dba;

-- Futuras migrações devem executar SET ROLE erp_dba para herdar estes padrões.
ALTER DEFAULT PRIVILEGES FOR ROLE erp_dba REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE erp_dba REVOKE ALL ON TABLES FROM PUBLIC;
-- Logs de conexão, TLS, backups e replicação são configurados fora do DDL.
-- DBA/proprietário pode modificar triggers: a trilha não é inviolável contra o DBA.

-- Administração de cadastros pelo CEO; rotinas continuam obrigatórias nos fatos derivados.
GRANT INSERT,UPDATE,DELETE ON cad.filial,cad.fornecedor,cad.centro_custo,
 sys.usuario,sys.perfil,sys.usuario_perfil,sys.parametro,fi.conta_contabil,fi.conta_bancaria,
 mm.produto,mm.deposito,pp.centro_trabalho,grc.risco,grc.controle,grc.auditoria_interna,
 grc.solicitacao_privacidade,fiscal.tributo,fiscal.documento_tributo,fiscal.obrigacao,
 portal.vinculo,portal.notificacao,api.conector,api.sensor TO erp_ceo;
