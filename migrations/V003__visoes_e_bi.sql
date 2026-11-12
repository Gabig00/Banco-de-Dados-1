-- V003: consultas operacionais e pequeno Data Warehouse com carga idempotente.
CREATE VIEW fi.v_titulos_abertos AS
SELECT t.*,t.valor-coalesce(b.total,0) AS saldo,
 CASE WHEN t.valor=coalesce(b.total,0) THEN 'LIQUIDADO'
      WHEN t.vencimento<CURRENT_DATE THEN 'VENCIDO' ELSE 'ABERTO' END AS situacao
FROM fi.titulo t LEFT JOIN (SELECT titulo_id,sum(valor) total FROM fi.baixa GROUP BY titulo_id) b ON b.titulo_id=t.id;
COMMENT ON VIEW fi.v_titulos_abertos IS 'Todos os títulos com saldo e situação calculados; filtrar saldo > 0 para títulos abertos.';

CREATE VIEW fi.v_fluxo_caixa AS
SELECT filial_id,vencimento AS data,tipo,sum(saldo) valor,'PREVISTO'::text cenario
FROM fi.v_titulos_abertos WHERE saldo>0 GROUP BY filial_id,vencimento,tipo
UNION ALL
SELECT t.filial_id,b.data,t.tipo,sum(b.valor),'REALIZADO'
FROM fi.baixa b JOIN fi.titulo t ON t.id=b.titulo_id GROUP BY t.filial_id,b.data,t.tipo;

CREATE VIEW fi.v_balancete AS
SELECT l.filial_id,c.codigo,c.nome,
 sum(CASE p.natureza WHEN 'D' THEN p.valor ELSE 0 END) debitos,
 sum(CASE p.natureza WHEN 'C' THEN p.valor ELSE 0 END) creditos,
 sum(CASE p.natureza WHEN 'D' THEN p.valor ELSE -p.valor END) saldo_devedor
FROM fi.partida p JOIN fi.conta_contabil c ON c.id=p.conta_id
JOIN fi.lancamento l ON l.id=p.lancamento_id WHERE l.status='CONTABILIZADO'
GROUP BY l.filial_id,c.codigo,c.nome;

CREATE VIEW fi.v_orcamento_realizado AS
SELECT o.id,o.centro_custo_id,o.conta_id,o.competencia,o.valor orcado,
 coalesce((SELECT sum(CASE p.natureza WHEN 'D' THEN p.valor ELSE -p.valor END)
 FROM fi.partida p JOIN fi.lancamento l ON l.id=p.lancamento_id
 WHERE l.status='CONTABILIZADO' AND p.centro_custo_id=o.centro_custo_id AND p.conta_id=o.conta_id
 AND l.data>=o.competencia AND l.data<(o.competencia+interval '1 month')::date),0) realizado
FROM fi.orcamento o;

CREATE VIEW mm.v_estoque AS
SELECT d.filial_id,d.id deposito_id,d.nome deposito,p.id produto_id,p.sku,p.nome produto,
 coalesce(e.quantidade,0) quantidade,p.estoque_minimo,
 greatest(p.estoque_minimo-coalesce(e.quantidade,0),0) reposicao_sugerida
FROM mm.deposito d CROSS JOIN mm.produto p
LEFT JOIN mm.estoque e ON e.deposito_id=d.id AND e.produto_id=p.id;

CREATE VIEW rh.v_folha_resumo AS
SELECT f.id folha_id,f.competencia,f.status,c.id colaborador_id,c.nome,
 sum(CASE r.tipo WHEN 'P' THEN i.valor ELSE 0 END) proventos,
 sum(CASE r.tipo WHEN 'D' THEN i.valor ELSE 0 END) descontos,
 sum(CASE r.tipo WHEN 'P' THEN i.valor ELSE -i.valor END) liquido
FROM rh.folha f JOIN rh.folha_item i ON i.folha_id=f.id
JOIN rh.rubrica r ON r.id=i.rubrica_id JOIN rh.colaborador c ON c.id=i.colaborador_id
GROUP BY f.id,c.id;

-- MRP simplificado de um nível: necessidades de ordens abertas e saldo por depósito.
-- Não desconta recebimentos futuros nem calcula lead time ou lotes econômicos.
CREATE VIEW pp.v_mrp AS
SELECT o.deposito_id,c.produto_id,sum(c.quantidade) necessidade,
 coalesce(e.quantidade,0) disponivel,
 greatest(sum(c.quantidade)-coalesce(e.quantidade,0),0) falta
FROM pp.ordem o JOIN pp.ordem_componente c ON c.ordem_id=o.id
LEFT JOIN mm.estoque e ON e.produto_id=c.produto_id AND e.deposito_id=o.deposito_id
WHERE o.status='ABERTA' GROUP BY o.deposito_id,c.produto_id,e.quantidade;
CREATE VIEW pp.v_capacidade AS
SELECT c.id centro_id,c.nome,o.prevista_para,sum(o.horas_planejadas) horas_planejadas,
 c.horas_dia capacidade_diaria,sum(o.horas_planejadas)>c.horas_dia sobrecarga
FROM pp.ordem o JOIN pp.centro_trabalho c ON c.id=o.centro_trabalho_id
WHERE o.status='ABERTA' GROUP BY c.id,o.prevista_para;

-- Subconsultas independentes evitam multiplicar orçamento por quantidade de apontamentos.
CREATE VIEW ps.v_indicadores AS
SELECT p.id,p.nome,p.orcamento,
 coalesce((SELECT avg(t.progresso) FROM ps.tarefa t WHERE t.projeto_id=p.id),0) progresso_medio,
 coalesce((SELECT sum(a.horas_previstas*a.custo_hora) FROM ps.alocacao a JOIN ps.tarefa t ON t.id=a.tarefa_id WHERE t.projeto_id=p.id),0) custo_planejado,
 coalesce((SELECT sum(ap.horas*a.custo_hora) FROM ps.apontamento ap JOIN ps.alocacao a ON a.id=ap.alocacao_id JOIN ps.tarefa t ON t.id=a.tarefa_id WHERE t.projeto_id=p.id),0) custo_realizado
FROM ps.projeto p;
CREATE VIEW sm.v_sla AS
SELECT o.*,coalesce(o.concluida_em,CURRENT_TIMESTAMP)>o.prazo_em sla_violado
FROM sm.ordem_servico o;
CREATE VIEW am.v_valor_contabil AS
SELECT a.id,a.patrimonio,a.valor_aquisicao,coalesce(sum(d.valor),0) depreciacao_acumulada,
 a.valor_aquisicao-coalesce(sum(d.valor),0) valor_contabil
FROM am.ativo a LEFT JOIN am.depreciacao d ON d.ativo_id=a.id GROUP BY a.id;
CREATE VIEW fiscal.v_livro_saida AS
SELECT d.id,d.numero,d.emitido_em,p.cliente_id,dep.filial_id,d.valor,d.status,
 coalesce((SELECT sum(t.valor) FROM fiscal.documento_tributo t WHERE t.documento_id=d.id),0) tributos_informados
FROM fiscal.documento d JOIN sd.pedido p ON p.id=d.pedido_id JOIN mm.deposito dep ON dep.id=p.deposito_id;
CREATE VIEW grc.v_riscos AS SELECT r.*,r.probabilidade*r.impacto pontuacao FROM grc.risco r;

-- Dimensões SCD tipo 1: alteração do nome atualiza a dimensão, sem histórico SCD2.
CREATE TABLE bi.dim_data (data date PRIMARY KEY,ano integer NOT NULL,mes integer NOT NULL,trimestre integer NOT NULL);
CREATE TABLE bi.dim_produto (produto_id bigint PRIMARY KEY,sku text NOT NULL,nome text NOT NULL);
CREATE TABLE bi.dim_cliente (cliente_id bigint PRIMARY KEY,nome text NOT NULL);
CREATE TABLE bi.fato_venda (
 pedido_item_id bigint PRIMARY KEY, data date NOT NULL REFERENCES bi.dim_data,
 produto_id bigint NOT NULL REFERENCES bi.dim_produto,cliente_id bigint NOT NULL REFERENCES bi.dim_cliente,
 filial_id bigint NOT NULL REFERENCES cad.filial, quantidade numeric(16,3) NOT NULL, valor numeric(16,2) NOT NULL
);
COMMENT ON TABLE bi.fato_venda IS 'Grão: um item de pedido faturado; valor líquido do desconto, sem cálculo de lucro/CMV.';
CREATE INDEX ON bi.fato_venda(data,filial_id);
CREATE INDEX ON bi.fato_venda(produto_id);
CREATE INDEX ON bi.fato_venda(cliente_id);
CREATE PROCEDURE bi.carregar_dw()
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(-82002::bigint);
 INSERT INTO bi.dim_data SELECT DISTINCT d.emitido_em::date,extract(year FROM d.emitido_em)::integer,
 extract(month FROM d.emitido_em)::integer,extract(quarter FROM d.emitido_em)::integer FROM fiscal.documento d ON CONFLICT DO NOTHING;
 INSERT INTO bi.dim_produto SELECT id,sku,nome FROM mm.produto
 ON CONFLICT(produto_id) DO UPDATE SET sku=excluded.sku,nome=excluded.nome;
 INSERT INTO bi.dim_cliente SELECT c.id,p.nome FROM cad.cliente c JOIN cad.parceiro p ON p.id=c.parceiro_id
 ON CONFLICT(cliente_id) DO UPDATE SET nome=excluded.nome;
 INSERT INTO bi.fato_venda
 SELECT i.id,d.emitido_em::date,i.produto_id,p.cliente_id,dep.filial_id,i.quantidade,round(i.quantidade*i.preco_unitario,2)-i.desconto
 FROM sd.pedido_item i JOIN sd.pedido p ON p.id=i.pedido_id JOIN fiscal.documento d ON d.pedido_id=p.id
 JOIN mm.deposito dep ON dep.id=p.deposito_id WHERE p.status='FATURADO'
 ON CONFLICT(pedido_item_id) DO NOTHING;
END $$;
CREATE VIEW bi.v_vendas_mensais AS
SELECT d.ano,d.mes,f.filial_id,p.sku,p.nome produto,sum(f.quantidade) quantidade,sum(f.valor) receita
FROM bi.fato_venda f JOIN bi.dim_data d ON d.data=f.data JOIN bi.dim_produto p ON p.produto_id=f.produto_id
GROUP BY d.ano,d.mes,f.filial_id,p.sku,p.nome;

-- View materializada: snapshot de consulta rápida; atualizar após a carga do DW.
CREATE MATERIALIZED VIEW bi.mv_receita_mensal AS
SELECT date_trunc('month',data)::date competencia,filial_id,sum(valor) receita
FROM bi.fato_venda GROUP BY 1,2 WITH NO DATA;
CREATE UNIQUE INDEX ON bi.mv_receita_mensal(competencia,filial_id);
CREATE PROCEDURE bi.atualizar_indicadores()
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN CALL bi.carregar_dw(); REFRESH MATERIALIZED VIEW bi.mv_receita_mensal; END $$;
