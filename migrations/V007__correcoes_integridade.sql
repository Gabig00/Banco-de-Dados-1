-- V007: correções identificadas na segunda rodada de testes.
-- Migração incremental: mantém V001 a V006 intactas e preserva os dados existentes.
-- Execute como administrador ou membro de erp_dba. Se houver dados inconsistentes,
-- a migração falha e deve ser revertida integralmente; nunca os corrige silenciosamente.
SET ROLE erp_dba;

-- NaN é um NUMERIC válido no PostgreSQL e pode passar por CHECK (valor > 0).
-- Bloqueia números especiais em TODAS as colunas numéricas do projeto.
DO $$
DECLARE r record;
BEGIN
 FOR r IN
 SELECT n.nspname,c.relname,a.attname
 FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
 JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE c.relkind IN ('r','p') AND NOT c.relispartition AND a.attnum>0
 AND NOT a.attisdropped AND a.atttypid='numeric'::regtype
 AND n.nspname=ANY(ARRAY['cad','sys','fi','rh','mm','sd','pp','ps','sm','bi','grc','qm','am','fiscal','portal','api'])
 LOOP
   EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I CHECK (%I IS NULL OR %I::text NOT IN (''NaN'',''Infinity'',''-Infinity''))',
     r.nspname,r.relname,'finito_'||r.attname,r.attname,r.attname);
 END LOOP;
END $$;

-- Recusa históricos já inconsistentes em vez de validar apenas operações futuras.
DO $$
BEGIN
 IF EXISTS(SELECT 1 FROM am.ativo a JOIN am.depreciacao d ON d.ativo_id=a.id
 GROUP BY a.id HAVING sum(d.valor)>a.valor_aquisicao-a.valor_residual OR count(*)>a.vida_util_meses) THEN
   RAISE EXCEPTION 'Migração bloqueada: depreciação histórica incompatível com a base';
 END IF;
 IF EXISTS(SELECT 1 FROM qm.inspecao i JOIN qm.plano_amostragem p ON p.id=i.plano_id
 JOIN qm.lote l ON l.id=i.lote_id WHERE l.produto_id<>p.produto_id OR i.defeitos>p.tamanho_amostra
 OR i.resultado<>CASE WHEN i.defeitos<=p.max_defeitos THEN 'APROVADO' ELSE 'REPROVADO' END) THEN
   RAISE EXCEPTION 'Migração bloqueada: inspeção histórica incompatível com plano';
 END IF;
 IF EXISTS(SELECT 1 FROM ps.tarefa t JOIN ps.projeto p ON p.id=t.projeto_id
 WHERE t.inicio<p.inicio OR t.fim>p.fim_previsto) THEN
   RAISE EXCEPTION 'Migração bloqueada: cronograma histórico inconsistente';
 END IF;
END $$;

-- Uma identidade estrutural não deve mudar de significado após ser referenciada.
-- Para transferir depósito/contrato/lote a outro proprietário, crie outro cadastro.
CREATE FUNCTION sys.proteger_identidade() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE campo text;
BEGIN
 FOREACH campo IN ARRAY TG_ARGV LOOP
   IF to_jsonb(OLD)->campo IS DISTINCT FROM to_jsonb(NEW)->campo THEN
     RAISE EXCEPTION 'Identidade estrutural imutável: %.%.%',TG_TABLE_SCHEMA,TG_TABLE_NAME,campo;
   END IF;
 END LOOP;
 RETURN NEW;
END $$;
CREATE TRIGGER identidade BEFORE UPDATE ON cad.cliente FOR EACH ROW EXECUTE FUNCTION sys.proteger_identidade('parceiro_id');
CREATE TRIGGER identidade BEFORE UPDATE ON cad.fornecedor FOR EACH ROW EXECUTE FUNCTION sys.proteger_identidade('parceiro_id');
CREATE TRIGGER identidade BEFORE UPDATE ON cad.centro_custo FOR EACH ROW EXECUTE FUNCTION sys.proteger_identidade('filial_id');
CREATE TRIGGER identidade BEFORE UPDATE ON mm.deposito FOR EACH ROW EXECUTE FUNCTION sys.proteger_identidade('filial_id');
CREATE TRIGGER identidade BEFORE UPDATE ON pp.centro_trabalho FOR EACH ROW EXECUTE FUNCTION sys.proteger_identidade('filial_id');
CREATE TRIGGER identidade BEFORE UPDATE ON fi.conta_bancaria FOR EACH ROW EXECUTE FUNCTION sys.proteger_identidade('filial_id','conta_contabil_id');
CREATE TRIGGER identidade BEFORE UPDATE ON sd.contrato FOR EACH ROW EXECUTE FUNCTION sys.proteger_identidade('cliente_id');
CREATE TRIGGER identidade BEFORE UPDATE ON sm.contrato_manutencao FOR EACH ROW EXECUTE FUNCTION sys.proteger_identidade('cliente_id');
CREATE TRIGGER identidade BEFORE UPDATE ON qm.lote FOR EACH ROW EXECUTE FUNCTION sys.proteger_identidade('produto_id','compra_id','ordem_producao_id');
-- Cada plano define critérios fixos. Mudança de amostragem exige outro plano.
CREATE TRIGGER identidade BEFORE UPDATE ON qm.plano_amostragem FOR EACH ROW EXECUTE FUNCTION sys.proteger_identidade('produto_id','tamanho_amostra','max_defeitos');
CREATE TRIGGER inspecao_imutavel BEFORE UPDATE OR DELETE ON qm.inspecao FOR EACH ROW EXECUTE FUNCTION sys.impedir_alteracao();
REVOKE UPDATE,DELETE ON qm.inspecao FROM erp_operacoes;

-- SLA congela contrato, abertura e prazo; encerrar é definitivo.
CREATE FUNCTION sm.proteger_sla() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF OLD.status='CONCLUIDA' THEN RAISE EXCEPTION 'Ordem de serviço concluída é imutável'; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 IF NEW.contrato_id IS DISTINCT FROM OLD.contrato_id OR NEW.aberta_em IS DISTINCT FROM OLD.aberta_em
 OR NEW.prazo_em IS DISTINCT FROM OLD.prazo_em THEN
   RAISE EXCEPTION 'Contrato, abertura e prazo de SLA são imutáveis após a abertura';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER proteger_sla BEFORE UPDATE OR DELETE ON sm.ordem_servico FOR EACH ROW EXECUTE FUNCTION sm.proteger_sla();

-- Reserva lógica do técnico sem conceder ao operador permissão para editar o RH.
CREATE OR REPLACE FUNCTION sm.validar_agenda() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(82004,hashint8(NEW.tecnico_id));
 IF EXISTS(SELECT 1 FROM sm.agendamento a WHERE a.tecnico_id=NEW.tecnico_id AND a.id<>NEW.id
 AND tstzrange(a.inicio,a.fim,'[)') && tstzrange(NEW.inicio,NEW.fim,'[)')) THEN
   RAISE EXCEPTION 'Técnico já agendado neste intervalo';
 END IF;
 RETURN NEW;
END $$;
REVOKE UPDATE(nome) ON rh.colaborador FROM erp_operacoes;

-- Base de depreciação é congelada a partir da primeira quota.
CREATE FUNCTION am.proteger_base() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM am.depreciacao WHERE ativo_id=OLD.id) AND
 (NEW.valor_aquisicao IS DISTINCT FROM OLD.valor_aquisicao OR
  NEW.valor_residual IS DISTINCT FROM OLD.valor_residual OR
  NEW.vida_util_meses IS DISTINCT FROM OLD.vida_util_meses OR
  NEW.aquisicao IS DISTINCT FROM OLD.aquisicao) THEN
   RAISE EXCEPTION 'Ativo já depreciado: base, vida útil e aquisição são imutáveis';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER proteger_base BEFORE UPDATE ON am.ativo FOR EACH ROW EXECUTE FUNCTION am.proteger_base();
-- Quota zero pode ser necessária quando centavos se distribuem por muitos meses.
ALTER TABLE am.depreciacao DROP CONSTRAINT depreciacao_valor_check;
ALTER TABLE am.depreciacao ADD CONSTRAINT depreciacao_valor_check CHECK (valor>=0);
CREATE OR REPLACE PROCEDURE am.depreciar(p_ativo bigint,p_competencia date)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a am.ativo%ROWTYPE; acumulado numeric; quota numeric; n integer; ultima date;
BEGIN
 SELECT * INTO STRICT a FROM am.ativo WHERE id=p_ativo FOR UPDATE;
 IF p_competencia IS NULL OR NOT isfinite(p_competencia) OR extract(day FROM p_competencia)<>1
 OR p_competencia<date_trunc('month',a.aquisicao)::date THEN
   RAISE EXCEPTION 'Competência de depreciação inválida';
 END IF;
 SELECT count(*),coalesce(sum(valor),0),max(competencia) INTO n,acumulado,ultima
 FROM am.depreciacao WHERE ativo_id=p_ativo;
 IF n>=a.vida_util_meses OR acumulado>=a.valor_aquisicao-a.valor_residual THEN
   RAISE EXCEPTION 'Ativo sem saldo depreciável';
 END IF;
 -- A primeira quota pode iniciar na implantação; depois os meses são consecutivos.
 IF ultima IS NOT NULL AND p_competencia<>(ultima+interval '1 month')::date THEN
   RAISE EXCEPTION 'Competência deve ser o mês imediatamente posterior à última quota';
 END IF;
 -- Alvo acumulado distribui os centavos; a última quota encerra exatamente a base.
 quota:=round((a.valor_aquisicao-a.valor_residual)*(n+1)/a.vida_util_meses,2)-acumulado;
 IF quota<0 THEN RAISE EXCEPTION 'Histórico de depreciação incompatível com a base'; END IF;
 INSERT INTO am.depreciacao(ativo_id,competencia,valor) VALUES(p_ativo,p_competencia,quota);
END $$;

-- Conta analítica usada não pode virar sintética, nem trocar seu código/natureza.
CREATE FUNCTION fi.proteger_conta() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(-82005::bigint);
 IF TG_OP='UPDATE' AND (NEW.codigo IS DISTINCT FROM OLD.codigo OR NEW.natureza IS DISTINCT FROM OLD.natureza
 OR NEW.sintetica IS DISTINCT FROM OLD.sintetica) THEN
   RAISE EXCEPTION 'Código, natureza e tipo da conta são imutáveis; crie outra conta';
 END IF;
 IF EXISTS(WITH RECURSIVE caminho(id) AS (
   SELECT NEW.superior_id UNION
   SELECT c.superior_id FROM fi.conta_contabil c JOIN caminho p ON c.id=p.id WHERE c.id<>NEW.id
 ) SELECT 1 FROM caminho WHERE id=NEW.id) THEN RAISE EXCEPTION 'Hierarquia contábil cíclica'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER proteger_conta BEFORE INSERT OR UPDATE ON fi.conta_contabil FOR EACH ROW EXECUTE FUNCTION fi.proteger_conta();

-- As exclusões de BOM devem respeitar o mesmo lock usado para congelar uma ordem.
CREATE OR REPLACE FUNCTION pp.validar_bom() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(-82001::bigint);
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 IF EXISTS(WITH RECURSIVE caminho(id) AS (
   SELECT NEW.componente_id UNION
   SELECT b.componente_id FROM pp.bom b JOIN caminho c ON b.produto_id=c.id WHERE b.id<>NEW.id
 ) SELECT 1 FROM caminho WHERE id=NEW.produto_id) THEN RAISE EXCEPTION 'Estrutura de produto cíclica'; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER validar_bom ON pp.bom;
CREATE TRIGGER validar_bom BEFORE INSERT OR UPDATE OR DELETE ON pp.bom FOR EACH ROW EXECUTE FUNCTION pp.validar_bom();

-- Validação bilateral do cronograma: alteração de tarefa ou projeto deve manter a relação.
CREATE FUNCTION ps.validar_tarefa() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE p ps.projeto%ROWTYPE;
BEGIN
 SELECT * INTO STRICT p FROM ps.projeto WHERE id=NEW.projeto_id FOR UPDATE;
 IF NEW.inicio<p.inicio OR NEW.fim>p.fim_previsto THEN RAISE EXCEPTION 'Tarefa fora do cronograma do projeto'; END IF;
 RETURN NEW;
END $$;
CREATE FUNCTION ps.validar_projeto() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM ps.tarefa WHERE projeto_id=NEW.id AND (inicio<NEW.inicio OR fim>NEW.fim_previsto)) THEN
   RAISE EXCEPTION 'Novo cronograma exclui tarefas existentes';
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER validar_relacoes ON ps.tarefa;
CREATE TRIGGER validar_relacoes BEFORE INSERT OR UPDATE ON ps.tarefa FOR EACH ROW EXECUTE FUNCTION ps.validar_tarefa();
CREATE TRIGGER validar_cronograma BEFORE UPDATE ON ps.projeto FOR EACH ROW EXECUTE FUNCTION ps.validar_projeto();

-- O novo dado sensível fica fora de PUBLIC por padrão; as rotinas novas são triggers.
-- Permissões de rotinas substituídas por CREATE OR REPLACE são preservadas.
RESET ROLE;
