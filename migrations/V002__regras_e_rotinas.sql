-- V002: integridade, auditoria e operações transacionais.
-- SECURITY DEFINER permite operar tabelas protegidas sem conceder DML direto.
-- search_path fixo e nomes qualificados evitam substituição de objetos pelo chamador.
-- Não há COMMIT interno: cada CALL participa da transação do cliente.

CREATE FUNCTION grc.auditar() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v jsonb; anteriores jsonb; campos text[];
BEGIN
 v := CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
 anteriores := CASE WHEN TG_OP='UPDATE' THEN to_jsonb(OLD) ELSE '{}'::jsonb END;
 SELECT coalesce(array_agg(key ORDER BY key),ARRAY[]::text[]) INTO campos
 FROM jsonb_each(v) WHERE TG_OP <> 'UPDATE' OR value IS DISTINCT FROM anteriores->key;
 INSERT INTO grc.evento_auditoria(usuario_banco,papel_ativo,tabela,operacao,registro_id,campos,transacao)
 VALUES(session_user,coalesce(nullif(current_setting('role',true),'none'),session_user),
        TG_TABLE_SCHEMA||'.'||TG_TABLE_NAME,TG_OP,(v->>'id')::bigint,campos,txid_current());
 RETURN NULL;
END $$;

CREATE FUNCTION sys.impedir_alteracao() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION 'Registro imutável em %.%: operação % não permitida',TG_TABLE_SCHEMA,TG_TABLE_NAME,TG_OP;
END $$;

-- Protege documentos finalizados, inclusive se alguém tentar reabri-los.
CREATE FUNCTION sys.proteger_fechado() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF to_jsonb(OLD)->>'status' <> TG_ARGV[0] THEN
   RAISE EXCEPTION 'Documento finalizado em %.% não pode ser alterado',TG_TABLE_SCHEMA,TG_TABLE_NAME;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;

-- Um lock no pai serializa edição de itens e fechamento do documento.
CREATE FUNCTION sys.proteger_item() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE v jsonb; pai bigint; estado text;
BEGIN
 v:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
 IF TG_OP='UPDATE' AND (v->>TG_ARGV[2]) IS DISTINCT FROM (to_jsonb(OLD)->>TG_ARGV[2]) THEN
   RAISE EXCEPTION 'Não é permitido mover um item para outro documento';
 END IF;
 pai:=(v->>TG_ARGV[2])::bigint;
 EXECUTE format('SELECT status FROM %I.%I WHERE id=$1 FOR UPDATE',TG_ARGV[0],TG_ARGV[1]) INTO estado USING pai;
 IF estado IS DISTINCT FROM TG_ARGV[3] THEN RAISE EXCEPTION 'Documento pai inexistente ou finalizado'; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;

CREATE TRIGGER proteger_compra BEFORE UPDATE OR DELETE ON mm.compra FOR EACH ROW EXECUTE FUNCTION sys.proteger_fechado('ABERTA');
CREATE TRIGGER proteger_compra_item BEFORE INSERT OR UPDATE OR DELETE ON mm.compra_item FOR EACH ROW EXECUTE FUNCTION sys.proteger_item('mm','compra','compra_id','ABERTA');
CREATE TRIGGER proteger_pedido BEFORE UPDATE OR DELETE ON sd.pedido FOR EACH ROW EXECUTE FUNCTION sys.proteger_fechado('ABERTO');
CREATE TRIGGER proteger_pedido_item BEFORE INSERT OR UPDATE OR DELETE ON sd.pedido_item FOR EACH ROW EXECUTE FUNCTION sys.proteger_item('sd','pedido','pedido_id','ABERTO');
CREATE TRIGGER proteger_lancamento BEFORE UPDATE OR DELETE ON fi.lancamento FOR EACH ROW EXECUTE FUNCTION sys.proteger_fechado('RASCUNHO');
CREATE TRIGGER proteger_partida BEFORE INSERT OR UPDATE OR DELETE ON fi.partida FOR EACH ROW EXECUTE FUNCTION sys.proteger_item('fi','lancamento','lancamento_id','RASCUNHO');
CREATE TRIGGER proteger_folha BEFORE UPDATE OR DELETE ON rh.folha FOR EACH ROW EXECUTE FUNCTION sys.proteger_fechado('ABERTA');
CREATE TRIGGER proteger_folha_item BEFORE INSERT OR UPDATE OR DELETE ON rh.folha_item FOR EACH ROW EXECUTE FUNCTION sys.proteger_item('rh','folha','folha_id','ABERTA');
CREATE TRIGGER proteger_ordem BEFORE UPDATE OR DELETE ON pp.ordem FOR EACH ROW EXECUTE FUNCTION sys.proteger_fechado('ABERTA');
CREATE TRIGGER proteger_componente BEFORE INSERT OR UPDATE OR DELETE ON pp.ordem_componente FOR EACH ROW EXECUTE FUNCTION sys.proteger_item('pp','ordem','ordem_id','ABERTA');
CREATE TRIGGER proteger_inventario BEFORE UPDATE OR DELETE ON mm.inventario FOR EACH ROW EXECUTE FUNCTION sys.proteger_fechado('ABERTO');
CREATE TRIGGER proteger_contagem BEFORE INSERT OR UPDATE OR DELETE ON mm.inventario_item FOR EACH ROW EXECUTE FUNCTION sys.proteger_item('mm','inventario','inventario_id','ABERTO');

CREATE FUNCTION fi.validar_contabilizacao() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE saldo numeric; n integer;
BEGIN
 IF NEW.status='CONTABILIZADO' THEN
   SELECT count(*),sum(CASE natureza WHEN 'D' THEN valor ELSE -valor END) INTO n,saldo
   FROM fi.partida WHERE lancamento_id=NEW.id;
   IF n<2 OR saldo IS DISTINCT FROM 0::numeric THEN RAISE EXCEPTION 'Lançamento deve ter ao menos duas partidas e débitos = créditos'; END IF;
   IF EXISTS(SELECT 1 FROM fi.partida p JOIN fi.conta_contabil c ON c.id=p.conta_id
             WHERE p.lancamento_id=NEW.id AND c.sintetica) THEN RAISE EXCEPTION 'Conta sintética não recebe lançamento'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER validar_contabilizacao BEFORE INSERT OR UPDATE ON fi.lancamento FOR EACH ROW EXECUTE FUNCTION fi.validar_contabilizacao();

-- Helper privado: uma partida de débito e uma de crédito, ambas no mesmo valor.
CREATE FUNCTION fi.registrar_dupla(p_filial bigint,p_debito text,p_credito text,p_valor numeric,p_historico text,p_origem text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_id bigint; d bigint; c bigint;
BEGIN
 SELECT id INTO STRICT d FROM fi.conta_contabil WHERE codigo=p_debito AND NOT sintetica;
 SELECT id INTO STRICT c FROM fi.conta_contabil WHERE codigo=p_credito AND NOT sintetica;
 INSERT INTO fi.lancamento(filial_id,historico,origem) VALUES(p_filial,p_historico,p_origem) RETURNING id INTO v_id;
 INSERT INTO fi.partida(lancamento_id,conta_id,natureza,valor) VALUES(v_id,d,'D',p_valor),(v_id,c,'C',p_valor);
 UPDATE fi.lancamento SET status='CONTABILIZADO' WHERE id=v_id;
 RETURN v_id;
END $$;
CREATE PROCEDURE fi.contabilizar(p_lancamento bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM 1 FROM fi.lancamento WHERE id=p_lancamento AND status='RASCUNHO' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Lançamento inexistente ou já contabilizado'; END IF;
 UPDATE fi.lancamento SET status='CONTABILIZADO' WHERE id=p_lancamento;
END $$;

-- Saldos são alterados apenas por movimentos. UPDATE condicional impede saldo negativo.
-- Advisory lock por produto também serializa transferências e criação de novos saldos.
CREATE FUNCTION mm.atualizar_saldo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(NEW.produto_id);
 INSERT INTO mm.estoque(produto_id,deposito_id,quantidade) VALUES(NEW.produto_id,NEW.deposito_id,0)
 ON CONFLICT(produto_id,deposito_id) DO NOTHING;
 UPDATE mm.estoque SET quantidade=quantidade+NEW.quantidade
 WHERE produto_id=NEW.produto_id AND deposito_id=NEW.deposito_id AND quantidade+NEW.quantidade >= 0;
 IF NOT FOUND THEN RAISE EXCEPTION 'Estoque insuficiente: produto %, depósito %',NEW.produto_id,NEW.deposito_id; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER atualizar_saldo BEFORE INSERT ON mm.movimento FOR EACH ROW EXECUTE FUNCTION mm.atualizar_saldo();
CREATE TRIGGER movimento_imutavel BEFORE UPDATE OR DELETE ON mm.movimento FOR EACH ROW EXECUTE FUNCTION sys.impedir_alteracao();
CREATE TRIGGER baixa_imutavel BEFORE UPDATE OR DELETE ON fi.baixa FOR EACH ROW EXECUTE FUNCTION sys.impedir_alteracao();
CREATE TRIGGER titulo_imutavel BEFORE UPDATE OR DELETE ON fi.titulo FOR EACH ROW EXECUTE FUNCTION sys.impedir_alteracao();
CREATE TRIGGER depreciacao_imutavel BEFORE UPDATE OR DELETE ON am.depreciacao FOR EACH ROW EXECUTE FUNCTION sys.impedir_alteracao();
CREATE TRIGGER auditoria_imutavel BEFORE UPDATE OR DELETE ON grc.evento_auditoria FOR EACH ROW EXECUTE FUNCTION sys.impedir_alteracao();

CREATE PROCEDURE mm.receber_compra(p_compra bigint,p_vencimento date)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE cab mm.compra%ROWTYPE; item record; v_filial bigint; v_parceiro bigint; total numeric; titulo bigint;
BEGIN
 SELECT * INTO STRICT cab FROM mm.compra WHERE id=p_compra FOR UPDATE;
 IF cab.status <> 'ABERTA' THEN RAISE EXCEPTION 'Compra já recebida ou cancelada'; END IF;
 SELECT sum(round(quantidade*custo_unitario,2)) INTO total FROM mm.compra_item WHERE compra_id=p_compra;
 IF total IS NULL OR total<=0 THEN RAISE EXCEPTION 'Compra sem itens válidos'; END IF;
 SELECT filial_id INTO v_filial FROM mm.deposito WHERE id=cab.deposito_id;
 SELECT parceiro_id INTO v_parceiro FROM cad.fornecedor WHERE id=cab.fornecedor_id;
 FOR item IN SELECT * FROM mm.compra_item WHERE compra_id=p_compra ORDER BY produto_id LOOP
   INSERT INTO mm.movimento(produto_id,deposito_id,quantidade,motivo,origem)
   VALUES(item.produto_id,cab.deposito_id,item.quantidade,'RECEBIMENTO','COMPRA:'||p_compra);
 END LOOP;
 INSERT INTO fi.titulo(filial_id,parceiro_id,tipo,descricao,vencimento,valor,origem)
 VALUES(v_filial,v_parceiro,'PAGAR','Compra '||p_compra,p_vencimento,total,'COMPRA:'||p_compra) RETURNING id INTO titulo;
 PERFORM fi.registrar_dupla(v_filial,'1.03','2.01',total,'Recebimento de compra','COMPRA:'||p_compra);
 UPDATE mm.compra SET status='RECEBIDA',titulo_id=titulo WHERE id=p_compra;
 INSERT INTO api.outbox(tipo,agregado,agregado_id,payload) VALUES('compra.recebida','compra',p_compra,jsonb_build_object('titulo_id',titulo,'valor',total));
END $$;

CREATE PROCEDURE sd.faturar_pedido(p_pedido bigint,p_vencimento date)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE cab sd.pedido%ROWTYPE; item record; v_filial bigint; v_parceiro bigint; total numeric; titulo bigint;
BEGIN
 SELECT * INTO STRICT cab FROM sd.pedido WHERE id=p_pedido FOR UPDATE;
 IF cab.status <> 'ABERTO' THEN RAISE EXCEPTION 'Pedido já faturado ou cancelado'; END IF;
 SELECT sum(round(quantidade*preco_unitario,2)-desconto) INTO total FROM sd.pedido_item WHERE pedido_id=p_pedido;
 IF total IS NULL OR total <= 0 THEN RAISE EXCEPTION 'Pedido sem itens válidos'; END IF;
 SELECT filial_id INTO v_filial FROM mm.deposito WHERE id=cab.deposito_id;
 SELECT parceiro_id INTO v_parceiro FROM cad.cliente WHERE id=cab.cliente_id;
 FOR item IN SELECT * FROM sd.pedido_item WHERE pedido_id=p_pedido ORDER BY produto_id LOOP
   INSERT INTO mm.movimento(produto_id,deposito_id,quantidade,motivo,origem)
   VALUES(item.produto_id,cab.deposito_id,-item.quantidade,'VENDA','PEDIDO:'||p_pedido);
 END LOOP;
 INSERT INTO fi.titulo(filial_id,parceiro_id,tipo,descricao,vencimento,valor,origem)
 VALUES(v_filial,v_parceiro,'RECEBER','Venda '||p_pedido,p_vencimento,total,'PEDIDO:'||p_pedido) RETURNING id INTO titulo;
 INSERT INTO fiscal.documento(pedido_id,valor) VALUES(p_pedido,total);
 PERFORM fi.registrar_dupla(v_filial,'1.02','3.01',total,'Faturamento de venda','PEDIDO:'||p_pedido);
 UPDATE sd.pedido SET status='FATURADO',titulo_id=titulo WHERE id=p_pedido;
 INSERT INTO api.outbox(tipo,agregado,agregado_id,payload) VALUES('pedido.faturado','pedido',p_pedido,jsonb_build_object('titulo_id',titulo,'valor',total));
END $$;

-- Baixa com lock no título e chave idempotente. Repetição idêntica não cobra duas vezes.
CREATE PROCEDURE fi.baixar_titulo(p_titulo bigint,p_conta bigint,p_valor numeric,p_chave uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE t fi.titulo%ROWTYPE; b fi.baixa%ROWTYPE; saldo numeric; banco fi.conta_bancaria%ROWTYPE; codigo text; l bigint;
BEGIN
 IF p_valor IS NULL OR p_valor<=0 OR p_valor<>round(p_valor,2) OR p_chave IS NULL THEN RAISE EXCEPTION 'Informe valor positivo com até duas casas e chave UUID'; END IF;
 SELECT * INTO STRICT t FROM fi.titulo WHERE id=p_titulo FOR UPDATE;
 SELECT * INTO b FROM fi.baixa WHERE chave_idempotencia=p_chave;
 IF FOUND THEN
   IF b.titulo_id=p_titulo AND b.conta_bancaria_id=p_conta AND b.valor=p_valor THEN RETURN; END IF;
   RAISE EXCEPTION 'Chave idempotente reutilizada com dados diferentes';
 END IF;
 SELECT t.valor-coalesce(sum(valor),0) INTO saldo FROM fi.baixa WHERE titulo_id=p_titulo;
 IF p_valor>saldo THEN RAISE EXCEPTION 'Baixa excede saldo de %',saldo; END IF;
 SELECT * INTO STRICT banco FROM fi.conta_bancaria WHERE id=p_conta;
 IF banco.filial_id<>t.filial_id THEN RAISE EXCEPTION 'Conta bancária de outra filial'; END IF;
 SELECT c.codigo INTO codigo FROM fi.conta_contabil c WHERE c.id=banco.conta_contabil_id;
 l:=fi.registrar_dupla(t.filial_id,CASE t.tipo WHEN 'RECEBER' THEN codigo ELSE '2.01' END,
       CASE t.tipo WHEN 'RECEBER' THEN '1.02' ELSE codigo END,p_valor,'Baixa do título '||p_titulo,'BAIXA:'||p_chave);
 INSERT INTO fi.baixa(titulo_id,conta_bancaria_id,valor,chave_idempotencia,lancamento_id)
 VALUES(p_titulo,p_conta,p_valor,p_chave,l);
END $$;

CREATE FUNCTION fi.validar_conciliacao() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE e fi.extrato%ROWTYPE; b fi.baixa%ROWTYPE; sinal integer;
BEGIN
 SELECT * INTO STRICT e FROM fi.extrato WHERE id=NEW.extrato_id;
 SELECT * INTO STRICT b FROM fi.baixa WHERE id=NEW.baixa_id;
 SELECT CASE tipo WHEN 'RECEBER' THEN 1 ELSE -1 END INTO sinal FROM fi.titulo WHERE id=b.titulo_id;
 IF e.conta_bancaria_id<>b.conta_bancaria_id OR e.valor<>b.valor*sinal OR e.data<>b.data THEN
   RAISE EXCEPTION 'Conciliação exige mesma conta, data, valor e sentido';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER validar_conciliacao BEFORE INSERT OR UPDATE ON fi.conciliacao FOR EACH ROW EXECUTE FUNCTION fi.validar_conciliacao();
CREATE TRIGGER extrato_imutavel BEFORE UPDATE OR DELETE ON fi.extrato FOR EACH ROW EXECUTE FUNCTION sys.impedir_alteracao();

CREATE PROCEDURE mm.transferir(p_produto bigint,p_origem bigint,p_destino bigint,p_quantidade numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF p_origem=p_destino OR p_quantidade IS NULL OR p_quantidade<=0 OR p_quantidade<>round(p_quantidade,3) THEN RAISE EXCEPTION 'Transferência inválida'; END IF;
 IF (SELECT filial_id FROM mm.deposito WHERE id=p_origem) IS DISTINCT FROM
    (SELECT filial_id FROM mm.deposito WHERE id=p_destino) THEN RAISE EXCEPTION 'Transferência interna exige depósitos da mesma filial'; END IF;
 PERFORM pg_advisory_xact_lock(p_produto);
 INSERT INTO mm.movimento(produto_id,deposito_id,quantidade,motivo,origem) VALUES
 (p_produto,p_origem,-p_quantidade,'TRANSFERENCIA','TRANSACAO:'||txid_current()),
 (p_produto,p_destino,p_quantidade,'TRANSFERENCIA','TRANSACAO:'||txid_current());
END $$;

CREATE PROCEDURE mm.aplicar_inventario(p_inventario bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE cab mm.inventario%ROWTYPE; item record; saldo numeric;
BEGIN
 SELECT * INTO STRICT cab FROM mm.inventario WHERE id=p_inventario FOR UPDATE;
 IF cab.status<>'ABERTO' THEN RAISE EXCEPTION 'Inventário já aplicado'; END IF;
 IF NOT EXISTS(SELECT 1 FROM mm.inventario_item WHERE inventario_id=p_inventario) THEN RAISE EXCEPTION 'Inventário vazio'; END IF;
 FOR item IN SELECT * FROM mm.inventario_item WHERE inventario_id=p_inventario ORDER BY produto_id LOOP
   PERFORM pg_advisory_xact_lock(item.produto_id);
   SELECT quantidade INTO saldo FROM mm.estoque WHERE produto_id=item.produto_id AND deposito_id=cab.deposito_id;
   IF item.quantidade_contada<>coalesce(saldo,0) THEN
     INSERT INTO mm.movimento(produto_id,deposito_id,quantidade,motivo,origem)
     VALUES(item.produto_id,cab.deposito_id,item.quantidade_contada-coalesce(saldo,0),'INVENTARIO','INVENTARIO:'||p_inventario);
   END IF;
 END LOOP;
 UPDATE mm.inventario SET status='APLICADO' WHERE id=p_inventario;
END $$;

-- Serializa alterações da BOM para impedir ciclos também entre transações concorrentes.
CREATE FUNCTION pp.validar_bom() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(-82001::bigint);
 IF EXISTS(WITH RECURSIVE caminho(id) AS (
   SELECT NEW.componente_id UNION
   SELECT b.componente_id FROM pp.bom b JOIN caminho c ON b.produto_id=c.id WHERE b.id<>NEW.id
 ) SELECT 1 FROM caminho WHERE id=NEW.produto_id) THEN RAISE EXCEPTION 'Estrutura de produto cíclica'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER validar_bom BEFORE INSERT OR UPDATE ON pp.bom FOR EACH ROW EXECUTE FUNCTION pp.validar_bom();

-- Congela UM nível da BOM: submontagens são produzidas em ordens próprias.
CREATE FUNCTION pp.abrir_ordem(p_produto bigint,p_deposito bigint,p_centro bigint,p_quantidade numeric,p_data date,p_horas numeric)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v_id bigint;
BEGIN
 IF p_quantidade IS NULL OR p_quantidade<=0 OR p_quantidade<>round(p_quantidade,3) THEN RAISE EXCEPTION 'Quantidade inválida'; END IF;
 IF (SELECT filial_id FROM mm.deposito WHERE id=p_deposito) IS DISTINCT FROM
    (SELECT filial_id FROM pp.centro_trabalho WHERE id=p_centro) THEN RAISE EXCEPTION 'Centro e depósito devem pertencer à mesma filial'; END IF;
 PERFORM pg_advisory_xact_lock(-82001::bigint);
 IF NOT EXISTS(SELECT 1 FROM pp.bom WHERE produto_id=p_produto) THEN RAISE EXCEPTION 'Produto sem BOM'; END IF;
 INSERT INTO pp.ordem(produto_id,deposito_id,centro_trabalho_id,quantidade,prevista_para,horas_planejadas)
 VALUES(p_produto,p_deposito,p_centro,p_quantidade,p_data,p_horas) RETURNING id INTO v_id;
 INSERT INTO pp.ordem_componente(ordem_id,produto_id,quantidade)
 SELECT v_id,componente_id,round(quantidade*p_quantidade,3) FROM pp.bom WHERE produto_id=p_produto;
 RETURN v_id;
END $$;
CREATE PROCEDURE pp.concluir_ordem(p_ordem bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE cab pp.ordem%ROWTYPE; item record; produto bigint;
BEGIN
 SELECT * INTO STRICT cab FROM pp.ordem WHERE id=p_ordem FOR UPDATE;
 IF cab.status<>'ABERTA' THEN RAISE EXCEPTION 'Ordem já concluída ou cancelada'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pp.ordem_componente WHERE ordem_id=p_ordem) THEN RAISE EXCEPTION 'Ordem sem componentes'; END IF;
 -- Locks de todos os produtos em ordem estável, evitando deadlocks entre ordens.
 FOR produto IN SELECT produto_id FROM pp.ordem_componente WHERE ordem_id=p_ordem
                UNION SELECT cab.produto_id ORDER BY 1 LOOP
   PERFORM pg_advisory_xact_lock(produto);
 END LOOP;
 FOR item IN SELECT * FROM pp.ordem_componente WHERE ordem_id=p_ordem ORDER BY produto_id LOOP
   INSERT INTO mm.movimento(produto_id,deposito_id,quantidade,motivo,origem)
   VALUES(item.produto_id,cab.deposito_id,-item.quantidade,'CONSUMO_PRODUCAO','OP:'||p_ordem);
 END LOOP;
 INSERT INTO mm.movimento(produto_id,deposito_id,quantidade,motivo,origem)
 VALUES(cab.produto_id,cab.deposito_id,cab.quantidade,'PRODUCAO','OP:'||p_ordem);
 UPDATE pp.ordem SET status='CONCLUIDA' WHERE id=p_ordem;
 INSERT INTO api.outbox(tipo,agregado,agregado_id,payload) VALUES('producao.concluida','ordem',p_ordem,jsonb_build_object('produto_id',cab.produto_id,'quantidade',cab.quantidade));
END $$;

CREATE PROCEDURE rh.fechar_folha(p_folha bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE f rh.folha%ROWTYPE;
BEGIN
 SELECT * INTO STRICT f FROM rh.folha WHERE id=p_folha FOR UPDATE;
 IF f.status<>'ABERTA' THEN RAISE EXCEPTION 'Folha já fechada'; END IF;
 IF NOT EXISTS(SELECT 1 FROM rh.folha_item WHERE folha_id=p_folha) THEN RAISE EXCEPTION 'Folha vazia'; END IF;
 IF EXISTS(SELECT 1 FROM rh.folha_item i JOIN rh.colaborador c ON c.id=i.colaborador_id WHERE i.folha_id=p_folha AND c.filial_id<>f.filial_id) THEN RAISE EXCEPTION 'Colaborador de outra filial'; END IF;
 IF EXISTS(SELECT 1 FROM rh.folha_item i JOIN rh.rubrica r ON r.id=i.rubrica_id WHERE i.folha_id=p_folha GROUP BY colaborador_id HAVING sum(CASE r.tipo WHEN 'P' THEN valor ELSE -valor END)<0) THEN RAISE EXCEPTION 'Folha com valor líquido negativo'; END IF;
 UPDATE rh.folha SET status='FECHADA' WHERE id=p_folha;
 INSERT INTO api.outbox(tipo,agregado,agregado_id,payload) VALUES('folha.fechada','folha',p_folha,jsonb_build_object('competencia',f.competencia));
END $$;

CREATE PROCEDURE am.depreciar(p_ativo bigint,p_competencia date)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a am.ativo%ROWTYPE; saldo numeric; quota numeric;
BEGIN
 SELECT * INTO STRICT a FROM am.ativo WHERE id=p_ativo FOR UPDATE;
 IF p_competencia IS NULL OR extract(day FROM p_competencia)<>1 OR p_competencia<date_trunc('month',a.aquisicao)::date THEN RAISE EXCEPTION 'Competência de depreciação inválida'; END IF;
 IF EXISTS(SELECT 1 FROM am.depreciacao WHERE ativo_id=p_ativo AND competencia=p_competencia) THEN RAISE EXCEPTION 'Competência já depreciada'; END IF;
 SELECT a.valor_aquisicao-a.valor_residual-coalesce(sum(valor),0) INTO saldo FROM am.depreciacao WHERE ativo_id=p_ativo;
 quota:=least(saldo,round((a.valor_aquisicao-a.valor_residual)/a.vida_util_meses,2));
 IF quota<=0 THEN RAISE EXCEPTION 'Ativo sem saldo ou quota arredondada igual a zero'; END IF;
 INSERT INTO am.depreciacao(ativo_id,competencia,valor) VALUES(p_ativo,p_competencia,quota);
END $$;

CREATE FUNCTION sm.definir_sla() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE c sm.contrato_manutencao%ROWTYPE;
BEGIN
 SELECT * INTO STRICT c FROM sm.contrato_manutencao WHERE id=NEW.contrato_id;
 IF NEW.aberta_em::date NOT BETWEEN c.inicio AND c.fim THEN RAISE EXCEPTION 'Contrato fora de vigência'; END IF;
 NEW.prazo_em:=NEW.aberta_em+make_interval(hours=>c.sla_horas);
 RETURN NEW;
END $$;
CREATE TRIGGER definir_sla BEFORE INSERT ON sm.ordem_servico FOR EACH ROW EXECUTE FUNCTION sm.definir_sla();

CREATE FUNCTION qm.validar_inspecao() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE plano qm.plano_amostragem%ROWTYPE; produto bigint;
BEGIN
 SELECT * INTO STRICT plano FROM qm.plano_amostragem WHERE id=NEW.plano_id;
 SELECT produto_id INTO STRICT produto FROM qm.lote WHERE id=NEW.lote_id;
 IF produto<>plano.produto_id OR NEW.defeitos>plano.tamanho_amostra THEN RAISE EXCEPTION 'Plano incompatível ou número de defeitos inválido'; END IF;
 NEW.resultado:=CASE WHEN NEW.defeitos<=plano.max_defeitos THEN 'APROVADO' ELSE 'REPROVADO' END;
 RETURN NEW;
END $$;
CREATE TRIGGER validar_inspecao BEFORE INSERT OR UPDATE ON qm.inspecao FOR EACH ROW EXECUTE FUNCTION qm.validar_inspecao();

-- Chaves de cifra são parâmetros, jamais constantes nos scripts ou na tabela de parâmetros.
-- Em produção, use TLS e parâmetros bind; evite registrar parâmetros sensíveis em logs.
CREATE FUNCTION rh.cifrar(p_texto text,p_chave text) RETURNS bytea
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF p_chave IS NULL OR length(p_chave)<32 THEN RAISE EXCEPTION 'Chave deve ter ao menos 32 caracteres'; END IF;
 RETURN extensoes.pgp_sym_encrypt(p_texto,p_chave,'cipher-algo=aes256');
END $$;
CREATE FUNCTION rh.decifrar(p_conteudo bytea,p_chave text) RETURNS text
LANGUAGE sql SET search_path=pg_catalog AS $$ SELECT extensoes.pgp_sym_decrypt(p_conteudo,p_chave) $$;

-- Auditoria em todas as tabelas de negócio comuns; a própria trilha não é auditada.
DO $$
DECLARE r record;
BEGIN
 FOR r IN SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE c.relkind='r' AND NOT c.relispartition AND n.nspname=ANY(ARRAY['cad','sys','fi','rh','mm','sd','pp','ps','sm','grc','qm','am','fiscal','portal','api'])
 LOOP
   EXECUTE format('CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION grc.auditar()',r.nspname,r.relname);
 END LOOP;
END $$;
