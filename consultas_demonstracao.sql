-- Consultas de apresentação. Executar após dados_demonstracao.sql.
-- 1. Compra: R$ 1.200 a pagar. Venda: R$ 450, dos quais R$ 200 recebidos.
SELECT id,tipo,descricao,valor,saldo,situacao FROM fi.v_titulos_abertos ORDER BY id;
-- 2. Estoque: 80 madeiras, 360 parafusos, 5 cadeiras no Principal e 2 na Expedição.
SELECT deposito,sku,quantidade,reposicao_sugerida FROM mm.v_estoque ORDER BY deposito,sku;
-- 3. Contabilidade: total de débitos e créditos deve ser igual.
SELECT * FROM fi.v_balancete ORDER BY codigo;
SELECT sum(debitos) debitos,sum(creditos) creditos FROM fi.v_balancete;
-- 4. Folha: R$ 4.000 de proventos, R$ 400 de descontos e R$ 3.600 líquidos.
SELECT * FROM rh.v_folha_resumo;
-- 5. MRP e ocupação do centro produtivo.
SELECT * FROM pp.v_mrp;
SELECT * FROM pp.v_capacidade;
-- 6. Projeto, SLA, patrimônio e risco.
SELECT * FROM ps.v_indicadores;
SELECT id,status,prazo_em,sla_violado FROM sm.v_sla;
SELECT * FROM am.v_valor_contabil;
SELECT descricao,pontuacao,tratamento FROM grc.v_riscos;
-- 7. Receita no DW; carga deve ser executada novamente após novos faturamentos.
CALL bi.atualizar_indicadores();
SELECT * FROM bi.v_vendas_mensais;
SELECT * FROM bi.mv_receita_mensal;
-- 8. Rastreabilidade documental de qualidade.
SELECT l.codigo,p.nome,i.etapa,i.resultado,n.descricao
FROM qm.lote l JOIN mm.produto p ON p.id=l.produto_id
JOIN qm.inspecao i ON i.lote_id=l.id LEFT JOIN qm.nao_conformidade n ON n.inspecao_id=i.id;
-- 9. Eventos que um worker externo poderá publicar; não há envio de rede pelo banco.
SELECT id,tipo,payload,publicado_em FROM api.outbox ORDER BY id;
-- 10. Auditoria sem copiar valores pessoais para a trilha.
SELECT ocorrido_em,usuario_banco,papel_ativo,tabela,operacao,registro_id,campos
FROM grc.evento_auditoria ORDER BY ocorrido_em DESC,id DESC LIMIT 30;
-- 11. Demonstração dos índices: volumes pequenos podem favorecer Seq Scan legitimamente.
EXPLAIN (ANALYZE,BUFFERS) SELECT * FROM fi.titulo WHERE vencimento BETWEEN CURRENT_DATE AND CURRENT_DATE+30;
