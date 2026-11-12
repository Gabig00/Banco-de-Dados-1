-- V005: catálogos mínimos usados pelas rotinas; não são dados pessoais/de produção.
-- As contas 1.02, 1.03, 2.01 e 3.01 são contratos explícitos das rotinas financeiras.
INSERT INTO fi.conta_contabil(codigo,nome,natureza) VALUES
('1.01','Bancos','ATIVO'),('1.02','Clientes a receber','ATIVO'),
('1.03','Estoques','ATIVO'),('2.01','Fornecedores a pagar','PASSIVO'),
('3.01','Receita de vendas','RECEITA'),('4.01','Despesas operacionais','DESPESA');
INSERT INTO rh.rubrica(codigo,descricao,tipo) VALUES
('SALARIO','Salário base informado','P'),('DESCONTO','Descontos informados','D');
INSERT INTO sd.etapa_funil(nome,ordem) VALUES('Prospecção',1),('Qualificação',2),('Proposta',3),('Negociação',4),('Ganho',5),('Perdido',6);
INSERT INTO fiscal.tributo(codigo,nome) VALUES('ICMS','ICMS'),('ISS','ISS'),('PIS','PIS'),('COFINS','COFINS');
INSERT INTO sys.parametro(chave,valor) VALUES
('instalacao','{"escopo":"organizacao_unica","moeda":"BRL","versao":1}'),
('fiscal','{"emissao_externa":true,"calculo_legal_automatizado":false}');
INSERT INTO sys.perfil(nome,papel_postgres) VALUES
('DBA','erp_dba'),('CEO','erp_ceo'),('Diretor','erp_diretor'),
('Gerente financeiro','erp_financeiro'),('Gerente RH','erp_rh'),
('Supervisor estoque','erp_estoque'),('Comercial','erp_comercial'),
('Produção','erp_producao'),('Serviços e projetos','erp_operacoes'),
('Auditor','erp_auditor'),('Analista BI','erp_bi'),('Integração','erp_integracao');
