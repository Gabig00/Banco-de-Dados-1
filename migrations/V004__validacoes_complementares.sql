-- V004: validações de relações que não cabem em CHECK de uma única linha.
CREATE FUNCTION sys.validar_relacoes() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE filial bigint; produto bigint; cliente bigint; conta_sintetica boolean;
BEGIN
 CASE TG_TABLE_SCHEMA||'.'||TG_TABLE_NAME
 WHEN 'rh.colaborador' THEN
   SELECT filial_id INTO filial FROM cad.centro_custo WHERE id=NEW.centro_custo_id;
   IF filial<>NEW.filial_id THEN RAISE EXCEPTION 'Centro de custo de outra filial'; END IF;
 WHEN 'fi.partida' THEN
   SELECT sintetica INTO conta_sintetica FROM fi.conta_contabil WHERE id=NEW.conta_id;
   IF conta_sintetica THEN RAISE EXCEPTION 'Conta sintética não recebe partidas'; END IF;
   IF NEW.centro_custo_id IS NOT NULL THEN
     SELECT filial_id INTO filial FROM cad.centro_custo WHERE id=NEW.centro_custo_id;
     IF filial<>(SELECT filial_id FROM fi.lancamento WHERE id=NEW.lancamento_id) THEN RAISE EXCEPTION 'Centro de custo de outra filial'; END IF;
   END IF;
 WHEN 'sd.pedido' THEN
   IF NEW.contrato_id IS NOT NULL THEN
     SELECT cliente_id INTO cliente FROM sd.contrato WHERE id=NEW.contrato_id;
     IF cliente<>NEW.cliente_id THEN RAISE EXCEPTION 'Contrato de outro cliente'; END IF;
   END IF;
 WHEN 'pp.ordem' THEN
   SELECT filial_id INTO filial FROM pp.centro_trabalho WHERE id=NEW.centro_trabalho_id;
   IF filial<>(SELECT filial_id FROM mm.deposito WHERE id=NEW.deposito_id) THEN RAISE EXCEPTION 'Centro de trabalho de outra filial'; END IF;
 WHEN 'qm.lote' THEN
   IF NEW.compra_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM mm.compra_item WHERE compra_id=NEW.compra_id AND produto_id=NEW.produto_id) THEN RAISE EXCEPTION 'Produto ausente na compra de origem'; END IF;
   IF NEW.ordem_producao_id IS NOT NULL THEN
     SELECT produto_id INTO produto FROM pp.ordem WHERE id=NEW.ordem_producao_id;
     IF produto<>NEW.produto_id THEN RAISE EXCEPTION 'Produto diferente da ordem de origem'; END IF;
   END IF;
 WHEN 'ps.tarefa' THEN
   IF NOT EXISTS(SELECT 1 FROM ps.projeto p WHERE p.id=NEW.projeto_id AND NEW.inicio>=p.inicio AND NEW.fim<=p.fim_previsto) THEN RAISE EXCEPTION 'Tarefa fora do cronograma do projeto'; END IF;
 END CASE;
 RETURN NEW;
END $$;
CREATE TRIGGER validar_relacoes BEFORE INSERT OR UPDATE ON rh.colaborador FOR EACH ROW EXECUTE FUNCTION sys.validar_relacoes();
CREATE TRIGGER validar_relacoes BEFORE INSERT OR UPDATE ON fi.partida FOR EACH ROW EXECUTE FUNCTION sys.validar_relacoes();
CREATE TRIGGER validar_relacoes BEFORE INSERT OR UPDATE ON sd.pedido FOR EACH ROW EXECUTE FUNCTION sys.validar_relacoes();
CREATE TRIGGER validar_relacoes BEFORE INSERT OR UPDATE ON pp.ordem FOR EACH ROW EXECUTE FUNCTION sys.validar_relacoes();
CREATE TRIGGER validar_relacoes BEFORE INSERT OR UPDATE ON qm.lote FOR EACH ROW EXECUTE FUNCTION sys.validar_relacoes();
CREATE TRIGGER validar_relacoes BEFORE INSERT OR UPDATE ON ps.tarefa FOR EACH ROW EXECUTE FUNCTION sys.validar_relacoes();

-- Bloqueio por colaborador impede intervalos de ponto sobrepostos.
CREATE FUNCTION rh.validar_ponto() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 PERFORM 1 FROM rh.colaborador WHERE id=NEW.colaborador_id FOR UPDATE;
 IF EXISTS(SELECT 1 FROM rh.ponto p WHERE p.colaborador_id=NEW.colaborador_id AND p.id<>NEW.id
 AND tstzrange(p.entrada,p.saida,'[)') && tstzrange(NEW.entrada,NEW.saida,'[)')) THEN
 RAISE EXCEPTION 'Intervalos de ponto sobrepostos'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER validar_ponto BEFORE INSERT OR UPDATE ON rh.ponto FOR EACH ROW EXECUTE FUNCTION rh.validar_ponto();

-- Agenda usa o mesmo princípio, sem depender de extensões de operadores GiST.
CREATE FUNCTION sm.validar_agenda() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 PERFORM 1 FROM rh.colaborador WHERE id=NEW.tecnico_id FOR UPDATE;
 IF EXISTS(SELECT 1 FROM sm.agendamento a WHERE a.tecnico_id=NEW.tecnico_id AND a.id<>NEW.id
 AND tstzrange(a.inicio,a.fim,'[)') && tstzrange(NEW.inicio,NEW.fim,'[)')) THEN
 RAISE EXCEPTION 'Técnico já agendado neste intervalo'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER validar_agenda BEFORE INSERT OR UPDATE ON sm.agendamento FOR EACH ROW EXECUTE FUNCTION sm.validar_agenda();
