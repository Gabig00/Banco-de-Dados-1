-- V001: estrutura relacional do ERP acadêmico (PostgreSQL 17 ou superior).
-- Execute em banco NOVO como administrador. Não apaga estruturas existentes.
-- Escopo: uma organização com filiais; não é um serviço multiempresa/multitenant.
-- Valores monetários usam NUMERIC; instantes usam TIMESTAMPTZ.
-- IDs técnicos são identidades; códigos de negócio recebem UNIQUE próprio.
-- Regras tributárias e trabalhistas são parametrizadas, não uma certificação legal.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA extensoes;
CREATE EXTENSION pgcrypto WITH SCHEMA extensoes;

CREATE SCHEMA cad;
CREATE SCHEMA sys;
CREATE SCHEMA fi;
CREATE SCHEMA rh;
CREATE SCHEMA mm;
CREATE SCHEMA sd;
CREATE SCHEMA pp;
CREATE SCHEMA ps;
CREATE SCHEMA sm;
CREATE SCHEMA bi;
CREATE SCHEMA grc;
CREATE SCHEMA qm;
CREATE SCHEMA am;
CREATE SCHEMA fiscal;
CREATE SCHEMA portal;
CREATE SCHEMA api;

-- Unidades da organização; CNPJ apenas com validação de formato.
CREATE TABLE cad.filial (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome text NOT NULL CHECK (btrim(nome) <> ''),
    cnpj varchar(14) NOT NULL UNIQUE CHECK (cnpj ~ '^[0-9]{14}$'),
    ativa boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE cad.filial IS 'Unidades da organização; CNPJ apenas com validação de formato.';

-- Cadastro mestre único de pessoas jurídicas ou físicas; dados fictícios na demonstração.
CREATE TABLE cad.parceiro (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome text NOT NULL CHECK (btrim(nome) <> ''),
    documento varchar(14) NOT NULL UNIQUE CHECK (documento ~ '^([0-9]{11}|[0-9]{14})$'),
    email text, telefone text, ativo boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE cad.parceiro IS 'Cadastro mestre único de pessoas jurídicas ou físicas; dados fictícios na demonstração.';

-- Papel de cliente associado ao cadastro mestre.
CREATE TABLE cad.cliente (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parceiro_id bigint NOT NULL UNIQUE REFERENCES cad.parceiro, limite_credito numeric(16,2) NOT NULL DEFAULT 0 CHECK (limite_credito >= 0)
);
COMMENT ON TABLE cad.cliente IS 'Papel de cliente associado ao cadastro mestre.';

-- Papel de fornecedor associado ao cadastro mestre.
CREATE TABLE cad.fornecedor (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parceiro_id bigint NOT NULL UNIQUE REFERENCES cad.parceiro, prazo_dias integer NOT NULL DEFAULT 30 CHECK (prazo_dias >= 0)
);
COMMENT ON TABLE cad.fornecedor IS 'Papel de fornecedor associado ao cadastro mestre.';

-- Centros para rateios, orçamento e projetos.
CREATE TABLE cad.centro_custo (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    filial_id bigint NOT NULL REFERENCES cad.filial, codigo text NOT NULL, nome text NOT NULL, UNIQUE(filial_id,codigo)
);
COMMENT ON TABLE cad.centro_custo IS 'Centros para rateios, orçamento e projetos.';

-- Mapeia identidade externa do portal; autenticação e tokens pertencem ao provedor de identidade.
CREATE TABLE sys.usuario (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    login text NOT NULL UNIQUE, nome text NOT NULL, identidade_externa text UNIQUE, ativo boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE sys.usuario IS 'Mapeia identidade externa do portal; autenticação e tokens pertencem ao provedor de identidade.';

-- Catálogo de perfis de aplicação; os papéis PostgreSQL são concedidos na V005.
CREATE TABLE sys.perfil (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome text NOT NULL UNIQUE, papel_postgres name NOT NULL UNIQUE
);
COMMENT ON TABLE sys.perfil IS 'Catálogo de perfis de aplicação; os papéis PostgreSQL são concedidos na V005.';

-- Perfis do portal; não concedem automaticamente privilégios a conexões SQL.
CREATE TABLE sys.usuario_perfil (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_id bigint NOT NULL REFERENCES sys.usuario, perfil_id bigint NOT NULL REFERENCES sys.perfil, UNIQUE(usuario_id,perfil_id)
);
COMMENT ON TABLE sys.usuario_perfil IS 'Perfis do portal; não concedem automaticamente privilégios a conexões SQL.';

-- Parâmetros não secretos do ERP; segredos não devem ficar nesta tabela.
CREATE TABLE sys.parametro (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    chave text NOT NULL UNIQUE, valor jsonb NOT NULL, CHECK (jsonb_typeof(valor) = 'object')
);
COMMENT ON TABLE sys.parametro IS 'Parâmetros não secretos do ERP; segredos não devem ficar nesta tabela.';

-- Plano de contas com hierarquia; lançamentos só usam contas analíticas.
CREATE TABLE fi.conta_contabil (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo text NOT NULL UNIQUE, nome text NOT NULL, natureza text NOT NULL CHECK (natureza IN ('ATIVO','PASSIVO','PATRIMONIO','RECEITA','DESPESA')), sintetica boolean NOT NULL DEFAULT false, superior_id bigint REFERENCES fi.conta_contabil, CHECK (superior_id IS DISTINCT FROM id)
);
COMMENT ON TABLE fi.conta_contabil IS 'Plano de contas com hierarquia; lançamentos só usam contas analíticas.';

-- Contas financeiras de uma filial.
CREATE TABLE fi.conta_bancaria (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    filial_id bigint NOT NULL REFERENCES cad.filial, banco text NOT NULL, agencia text NOT NULL, numero text NOT NULL, conta_contabil_id bigint NOT NULL REFERENCES fi.conta_contabil, UNIQUE(banco,agencia,numero)
);
COMMENT ON TABLE fi.conta_bancaria IS 'Contas financeiras de uma filial.';

-- Cabeçalho contábil; contabilizar exige partidas equilibradas.
CREATE TABLE fi.lancamento (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    filial_id bigint NOT NULL REFERENCES cad.filial, data date NOT NULL DEFAULT CURRENT_DATE, historico text NOT NULL, status text NOT NULL DEFAULT 'RASCUNHO' CHECK (status IN ('RASCUNHO','CONTABILIZADO')), origem text UNIQUE
);
COMMENT ON TABLE fi.lancamento IS 'Cabeçalho contábil; contabilizar exige partidas equilibradas.';

-- Partidas dobradas: cada linha é um débito ou um crédito positivo.
CREATE TABLE fi.partida (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lancamento_id bigint NOT NULL REFERENCES fi.lancamento, conta_id bigint NOT NULL REFERENCES fi.conta_contabil, centro_custo_id bigint REFERENCES cad.centro_custo, natureza char(1) NOT NULL CHECK (natureza IN ('D','C')), valor numeric(16,2) NOT NULL CHECK (valor > 0)
);
COMMENT ON TABLE fi.partida IS 'Partidas dobradas: cada linha é um débito ou um crédito positivo.';

-- Contas a pagar e receber; saldo calculado a partir das baixas.
CREATE TABLE fi.titulo (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    filial_id bigint NOT NULL REFERENCES cad.filial, parceiro_id bigint NOT NULL REFERENCES cad.parceiro, tipo text NOT NULL CHECK (tipo IN ('PAGAR','RECEBER')), descricao text NOT NULL, emissao date NOT NULL DEFAULT CURRENT_DATE, vencimento date NOT NULL, valor numeric(16,2) NOT NULL CHECK (valor > 0), origem text UNIQUE, CHECK (vencimento >= emissao)
);
COMMENT ON TABLE fi.titulo IS 'Contas a pagar e receber; saldo calculado a partir das baixas.';

-- Liquidações parciais ou totais, sempre por rotina transacional.
CREATE TABLE fi.baixa (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    titulo_id bigint NOT NULL REFERENCES fi.titulo, conta_bancaria_id bigint NOT NULL REFERENCES fi.conta_bancaria, valor numeric(16,2) NOT NULL CHECK (valor > 0), data date NOT NULL DEFAULT CURRENT_DATE, chave_idempotencia uuid NOT NULL UNIQUE, lancamento_id bigint NOT NULL UNIQUE REFERENCES fi.lancamento
);
COMMENT ON TABLE fi.baixa IS 'Liquidações parciais ou totais, sempre por rotina transacional.';

-- Linhas importadas do banco; chave externa evita duplicação da importação.
CREATE TABLE fi.extrato (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    conta_bancaria_id bigint NOT NULL REFERENCES fi.conta_bancaria, chave_externa text NOT NULL, data date NOT NULL, valor numeric(16,2) NOT NULL CHECK (valor <> 0), descricao text NOT NULL, UNIQUE(conta_bancaria_id,chave_externa)
);
COMMENT ON TABLE fi.extrato IS 'Linhas importadas do banco; chave externa evita duplicação da importação.';

-- Vínculo um a um entre extrato e liquidação, validado por trigger.
CREATE TABLE fi.conciliacao (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    extrato_id bigint NOT NULL UNIQUE REFERENCES fi.extrato, baixa_id bigint NOT NULL UNIQUE REFERENCES fi.baixa, conciliado_em timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE fi.conciliacao IS 'Vínculo um a um entre extrato e liquidação, validado por trigger.';

-- Orçamento mensal por centro de custo e conta contábil.
CREATE TABLE fi.orcamento (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    centro_custo_id bigint NOT NULL REFERENCES cad.centro_custo, conta_id bigint NOT NULL REFERENCES fi.conta_contabil, competencia date NOT NULL CHECK (extract(day FROM competencia)=1), valor numeric(16,2) NOT NULL CHECK (valor >= 0), UNIQUE(centro_custo_id,conta_id,competencia)
);
COMMENT ON TABLE fi.orcamento IS 'Orçamento mensal por centro de custo e conta contábil.';

-- Cargos e referência salarial.
CREATE TABLE rh.cargo (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome text NOT NULL UNIQUE, salario_referencia numeric(16,2) NOT NULL CHECK (salario_referencia >= 0)
);
COMMENT ON TABLE rh.cargo IS 'Cargos e referência salarial.';

-- Dados funcionais; documento pessoal e dados bancários ficam cifrados em tabela restrita.
CREATE TABLE rh.colaborador (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    filial_id bigint NOT NULL REFERENCES cad.filial, centro_custo_id bigint NOT NULL REFERENCES cad.centro_custo, cargo_id bigint NOT NULL REFERENCES rh.cargo, usuario_id bigint UNIQUE REFERENCES sys.usuario, matricula text NOT NULL UNIQUE, nome text NOT NULL, admissao date NOT NULL, desligamento date, salario_base numeric(16,2) NOT NULL CHECK (salario_base > 0), CHECK (desligamento IS NULL OR desligamento >= admissao)
);
COMMENT ON TABLE rh.colaborador IS 'Dados funcionais; documento pessoal e dados bancários ficam cifrados em tabela restrita.';

-- Conteúdo cifrado com pgcrypto; a chave é externa e nunca persistida no esquema.
CREATE TABLE rh.dado_sensivel (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    colaborador_id bigint NOT NULL UNIQUE REFERENCES rh.colaborador, conteudo_cifrado bytea NOT NULL, versao_chave text NOT NULL
);
COMMENT ON TABLE rh.dado_sensivel IS 'Conteúdo cifrado com pgcrypto; a chave é externa e nunca persistida no esquema.';

-- Catálogo de benefícios; concessão separada do colaborador.
CREATE TABLE rh.beneficio (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome text NOT NULL UNIQUE, valor_padrao numeric(16,2) NOT NULL CHECK (valor_padrao >= 0)
);
COMMENT ON TABLE rh.beneficio IS 'Catálogo de benefícios; concessão separada do colaborador.';

-- Benefícios concedidos e sua vigência.
CREATE TABLE rh.colaborador_beneficio (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    colaborador_id bigint NOT NULL REFERENCES rh.colaborador, beneficio_id bigint NOT NULL REFERENCES rh.beneficio, inicio date NOT NULL, fim date, valor numeric(16,2) NOT NULL CHECK (valor >= 0), CHECK (fim IS NULL OR fim >= inicio), UNIQUE(colaborador_id,beneficio_id,inicio)
);
COMMENT ON TABLE rh.colaborador_beneficio IS 'Benefícios concedidos e sua vigência.';

-- Intervalos de trabalho; duração calculável pelas marcações.
CREATE TABLE rh.ponto (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    colaborador_id bigint NOT NULL REFERENCES rh.colaborador, entrada timestamptz NOT NULL, saida timestamptz, CHECK (saida IS NULL OR saida > entrada), UNIQUE(colaborador_id,entrada)
);
COMMENT ON TABLE rh.ponto IS 'Intervalos de trabalho; duração calculável pelas marcações.';

-- Folha mensal; rubricas são informadas, sem presumir legislação trabalhista.
CREATE TABLE rh.folha (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    filial_id bigint NOT NULL REFERENCES cad.filial, competencia date NOT NULL CHECK (extract(day FROM competencia)=1), status text NOT NULL DEFAULT 'ABERTA' CHECK (status IN ('ABERTA','FECHADA')), UNIQUE(filial_id,competencia)
);
COMMENT ON TABLE rh.folha IS 'Folha mensal; rubricas são informadas, sem presumir legislação trabalhista.';

-- Rubricas de proventos e descontos.
CREATE TABLE rh.rubrica (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo text NOT NULL UNIQUE, descricao text NOT NULL, tipo char(1) NOT NULL CHECK (tipo IN ('P','D'))
);
COMMENT ON TABLE rh.rubrica IS 'Rubricas de proventos e descontos.';

-- Valores calculados externamente ou informados pelo RH para cada competência.
CREATE TABLE rh.folha_item (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    folha_id bigint NOT NULL REFERENCES rh.folha, colaborador_id bigint NOT NULL REFERENCES rh.colaborador, rubrica_id bigint NOT NULL REFERENCES rh.rubrica, valor numeric(16,2) NOT NULL CHECK (valor > 0), UNIQUE(folha_id,colaborador_id,rubrica_id)
);
COMMENT ON TABLE rh.folha_item IS 'Valores calculados externamente ou informados pelo RH para cada competência.';

-- Recrutamento: vagas por filial e cargo.
CREATE TABLE rh.vaga (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    filial_id bigint NOT NULL REFERENCES cad.filial, cargo_id bigint NOT NULL REFERENCES rh.cargo, titulo text NOT NULL, aberta_em date NOT NULL DEFAULT CURRENT_DATE, status text NOT NULL CHECK (status IN ('ABERTA','ENCERRADA'))
);
COMMENT ON TABLE rh.vaga IS 'Recrutamento: vagas por filial e cargo.';

-- Candidatos e andamento da seleção.
CREATE TABLE rh.candidatura (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vaga_id bigint NOT NULL REFERENCES rh.vaga, nome text NOT NULL, email text NOT NULL, etapa text NOT NULL CHECK (etapa IN ('INSCRICAO','ENTREVISTA','APROVADO','REPROVADO')), UNIQUE(vaga_id,email)
);
COMMENT ON TABLE rh.candidatura IS 'Candidatos e andamento da seleção.';

-- Avaliações de desempenho com nota entre zero e dez.
CREATE TABLE rh.avaliacao (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    colaborador_id bigint NOT NULL REFERENCES rh.colaborador, avaliador_id bigint NOT NULL REFERENCES rh.colaborador, data date NOT NULL, nota numeric(4,2) NOT NULL CHECK (nota BETWEEN 0 AND 10), observacao text, CHECK (colaborador_id <> avaliador_id)
);
COMMENT ON TABLE rh.avaliacao IS 'Avaliações de desempenho com nota entre zero e dez.';

-- Materiais, produtos acabados e parâmetros de reposição.
CREATE TABLE mm.produto (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku text NOT NULL UNIQUE, nome text NOT NULL, unidade varchar(10) NOT NULL, tipo text NOT NULL CHECK (tipo IN ('MATERIA_PRIMA','ACABADO','REVENDA')), preco_venda numeric(16,2) NOT NULL CHECK (preco_venda >= 0), estoque_minimo numeric(16,3) NOT NULL DEFAULT 0 CHECK (estoque_minimo >= 0), ativo boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE mm.produto IS 'Materiais, produtos acabados e parâmetros de reposição.';

-- Locais físicos de estoque por filial.
CREATE TABLE mm.deposito (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    filial_id bigint NOT NULL REFERENCES cad.filial, nome text NOT NULL, UNIQUE(filial_id,nome)
);
COMMENT ON TABLE mm.deposito IS 'Locais físicos de estoque por filial.';

-- Saldo agregado por produto e depósito; somente as rotinas movimentam o saldo.
CREATE TABLE mm.estoque (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    produto_id bigint NOT NULL REFERENCES mm.produto, deposito_id bigint NOT NULL REFERENCES mm.deposito, quantidade numeric(16,3) NOT NULL DEFAULT 0 CHECK (quantidade >= 0), UNIQUE(produto_id,deposito_id)
);
COMMENT ON TABLE mm.estoque IS 'Saldo agregado por produto e depósito; somente as rotinas movimentam o saldo.';

-- Pedido de compra; recebimento integral e único nesta versão.
CREATE TABLE mm.compra (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fornecedor_id bigint NOT NULL REFERENCES cad.fornecedor, deposito_id bigint NOT NULL REFERENCES mm.deposito, criada_em date NOT NULL DEFAULT CURRENT_DATE, status text NOT NULL DEFAULT 'ABERTA' CHECK (status IN ('ABERTA','RECEBIDA','CANCELADA')), titulo_id bigint UNIQUE REFERENCES fi.titulo
);
COMMENT ON TABLE mm.compra IS 'Pedido de compra; recebimento integral e único nesta versão.';

-- Itens e custos históricos da compra.
CREATE TABLE mm.compra_item (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    compra_id bigint NOT NULL REFERENCES mm.compra, produto_id bigint NOT NULL REFERENCES mm.produto, quantidade numeric(16,3) NOT NULL CHECK (quantidade > 0), custo_unitario numeric(16,2) NOT NULL CHECK (custo_unitario > 0), UNIQUE(compra_id,produto_id)
);
COMMENT ON TABLE mm.compra_item IS 'Itens e custos históricos da compra.';

-- Razão imutável de estoque; quantidade positiva entra e negativa sai.
CREATE TABLE mm.movimento (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    produto_id bigint NOT NULL REFERENCES mm.produto, deposito_id bigint NOT NULL REFERENCES mm.deposito, quantidade numeric(16,3) NOT NULL CHECK (quantidade <> 0), motivo text NOT NULL, origem text NOT NULL, criado_em timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE mm.movimento IS 'Razão imutável de estoque; quantidade positiva entra e negativa sai.';

-- Contagem física com ajuste único do saldo existente.
CREATE TABLE mm.inventario (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    deposito_id bigint NOT NULL REFERENCES mm.deposito, data date NOT NULL DEFAULT CURRENT_DATE, status text NOT NULL DEFAULT 'ABERTO' CHECK (status IN ('ABERTO','APLICADO'))
);
COMMENT ON TABLE mm.inventario IS 'Contagem física com ajuste único do saldo existente.';

-- Quantidade contada por produto.
CREATE TABLE mm.inventario_item (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    inventario_id bigint NOT NULL REFERENCES mm.inventario, produto_id bigint NOT NULL REFERENCES mm.produto, quantidade_contada numeric(16,3) NOT NULL CHECK (quantidade_contada >= 0), UNIQUE(inventario_id,produto_id)
);
COMMENT ON TABLE mm.inventario_item IS 'Quantidade contada por produto.';

-- Etapas ordenadas do funil comercial.
CREATE TABLE sd.etapa_funil (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome text NOT NULL UNIQUE, ordem integer NOT NULL UNIQUE CHECK (ordem > 0)
);
COMMENT ON TABLE sd.etapa_funil IS 'Etapas ordenadas do funil comercial.';

-- CRM: oportunidades, responsável e probabilidade.
CREATE TABLE sd.oportunidade (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cliente_id bigint NOT NULL REFERENCES cad.cliente, etapa_id bigint NOT NULL REFERENCES sd.etapa_funil, responsavel_id bigint REFERENCES sys.usuario, descricao text NOT NULL, valor_estimado numeric(16,2) NOT NULL CHECK (valor_estimado >= 0), probabilidade numeric(5,2) NOT NULL CHECK (probabilidade BETWEEN 0 AND 100)
);
COMMENT ON TABLE sd.oportunidade IS 'CRM: oportunidades, responsável e probabilidade.';

-- Histórico de contatos do CRM.
CREATE TABLE sd.interacao (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    oportunidade_id bigint NOT NULL REFERENCES sd.oportunidade, usuario_id bigint NOT NULL REFERENCES sys.usuario, ocorrida_em timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, descricao text NOT NULL
);
COMMENT ON TABLE sd.interacao IS 'Histórico de contatos do CRM.';

-- Contratos comerciais versionáveis pela aplicação.
CREATE TABLE sd.contrato (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cliente_id bigint NOT NULL REFERENCES cad.cliente, numero text NOT NULL UNIQUE, inicio date NOT NULL, fim date NOT NULL, valor numeric(16,2) NOT NULL CHECK (valor >= 0), CHECK (fim >= inicio)
);
COMMENT ON TABLE sd.contrato IS 'Contratos comerciais versionáveis pela aplicação.';

-- Pedido comercial faturado integralmente em operação atômica.
CREATE TABLE sd.pedido (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cliente_id bigint NOT NULL REFERENCES cad.cliente, deposito_id bigint NOT NULL REFERENCES mm.deposito, contrato_id bigint REFERENCES sd.contrato, criado_em date NOT NULL DEFAULT CURRENT_DATE, status text NOT NULL DEFAULT 'ABERTO' CHECK (status IN ('ABERTO','FATURADO','CANCELADO')), titulo_id bigint UNIQUE REFERENCES fi.titulo
);
COMMENT ON TABLE sd.pedido IS 'Pedido comercial faturado integralmente em operação atômica.';

-- Preços e descontos históricos; total arredondado por item.
CREATE TABLE sd.pedido_item (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pedido_id bigint NOT NULL REFERENCES sd.pedido, produto_id bigint NOT NULL REFERENCES mm.produto, quantidade numeric(16,3) NOT NULL CHECK (quantidade > 0), preco_unitario numeric(16,2) NOT NULL CHECK (preco_unitario > 0), desconto numeric(16,2) NOT NULL DEFAULT 0 CHECK (desconto >= 0), CHECK (round(quantidade * preco_unitario,2) > desconto), UNIQUE(pedido_id,produto_id)
);
COMMENT ON TABLE sd.pedido_item IS 'Preços e descontos históricos; total arredondado por item.';

-- Estrutura de materiais de um produto; ciclos indiretos bloqueados por trigger.
CREATE TABLE pp.bom (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    produto_id bigint NOT NULL REFERENCES mm.produto, componente_id bigint NOT NULL REFERENCES mm.produto, quantidade numeric(16,3) NOT NULL CHECK (quantidade > 0), CHECK (produto_id <> componente_id), UNIQUE(produto_id,componente_id)
);
COMMENT ON TABLE pp.bom IS 'Estrutura de materiais de um produto; ciclos indiretos bloqueados por trigger.';

-- Capacidade nominal dos centros de produção.
CREATE TABLE pp.centro_trabalho (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    filial_id bigint NOT NULL REFERENCES cad.filial, nome text NOT NULL, horas_dia numeric(5,2) NOT NULL CHECK (horas_dia > 0 AND horas_dia <= 24), UNIQUE(filial_id,nome)
);
COMMENT ON TABLE pp.centro_trabalho IS 'Capacidade nominal dos centros de produção.';

-- Ordens de produção; conclusão consome os componentes congelados.
CREATE TABLE pp.ordem (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    produto_id bigint NOT NULL REFERENCES mm.produto, deposito_id bigint NOT NULL REFERENCES mm.deposito, centro_trabalho_id bigint NOT NULL REFERENCES pp.centro_trabalho, quantidade numeric(16,3) NOT NULL CHECK (quantidade > 0), prevista_para date NOT NULL, horas_planejadas numeric(10,2) NOT NULL CHECK (horas_planejadas > 0), status text NOT NULL DEFAULT 'ABERTA' CHECK (status IN ('ABERTA','CONCLUIDA','CANCELADA'))
);
COMMENT ON TABLE pp.ordem IS 'Ordens de produção; conclusão consome os componentes congelados.';

-- Snapshot dos componentes da ordem; não muda com alterações futuras na BOM.
CREATE TABLE pp.ordem_componente (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ordem_id bigint NOT NULL REFERENCES pp.ordem, produto_id bigint NOT NULL REFERENCES mm.produto, quantidade numeric(16,3) NOT NULL CHECK (quantidade > 0), UNIQUE(ordem_id,produto_id)
);
COMMENT ON TABLE pp.ordem_componente IS 'Snapshot dos componentes da ordem; não muda com alterações futuras na BOM.';

-- Apontamentos do chão de fábrica.
CREATE TABLE pp.apontamento (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ordem_id bigint NOT NULL REFERENCES pp.ordem, colaborador_id bigint NOT NULL REFERENCES rh.colaborador, inicio timestamptz NOT NULL, fim timestamptz NOT NULL, quantidade_boa numeric(16,3) NOT NULL CHECK (quantidade_boa >= 0), quantidade_refugo numeric(16,3) NOT NULL CHECK (quantidade_refugo >= 0), CHECK (fim > inicio)
);
COMMENT ON TABLE pp.apontamento IS 'Apontamentos do chão de fábrica.';

-- Projetos com orçamento, cronograma e responsável.
CREATE TABLE ps.projeto (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    centro_custo_id bigint NOT NULL REFERENCES cad.centro_custo, nome text NOT NULL, responsavel_id bigint NOT NULL REFERENCES rh.colaborador, inicio date NOT NULL, fim_previsto date NOT NULL, orcamento numeric(16,2) NOT NULL CHECK (orcamento >= 0), CHECK (fim_previsto >= inicio)
);
COMMENT ON TABLE ps.projeto IS 'Projetos com orçamento, cronograma e responsável.';

-- Cronograma e progresso das tarefas.
CREATE TABLE ps.tarefa (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    projeto_id bigint NOT NULL REFERENCES ps.projeto, nome text NOT NULL, inicio date NOT NULL, fim date NOT NULL, progresso numeric(5,2) NOT NULL DEFAULT 0 CHECK (progresso BETWEEN 0 AND 100), CHECK (fim >= inicio)
);
COMMENT ON TABLE ps.tarefa IS 'Cronograma e progresso das tarefas.';

-- Horas planejadas e custo hora de recursos por tarefa.
CREATE TABLE ps.alocacao (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tarefa_id bigint NOT NULL REFERENCES ps.tarefa, colaborador_id bigint NOT NULL REFERENCES rh.colaborador, horas_previstas numeric(10,2) NOT NULL CHECK (horas_previstas > 0), custo_hora numeric(16,2) NOT NULL CHECK (custo_hora >= 0), UNIQUE(tarefa_id,colaborador_id)
);
COMMENT ON TABLE ps.alocacao IS 'Horas planejadas e custo hora de recursos por tarefa.';

-- Execução das tarefas e custo efetivo calculável.
CREATE TABLE ps.apontamento (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    alocacao_id bigint NOT NULL REFERENCES ps.alocacao, data date NOT NULL, horas numeric(5,2) NOT NULL CHECK (horas > 0 AND horas <= 24), descricao text NOT NULL
);
COMMENT ON TABLE ps.apontamento IS 'Execução das tarefas e custo efetivo calculável.';

-- Contratos de serviço com SLA corrido, em horas.
CREATE TABLE sm.contrato_manutencao (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cliente_id bigint NOT NULL REFERENCES cad.cliente, numero text NOT NULL UNIQUE, inicio date NOT NULL, fim date NOT NULL, sla_horas integer NOT NULL CHECK (sla_horas > 0), valor_mensal numeric(16,2) NOT NULL CHECK (valor_mensal >= 0), CHECK (fim >= inicio)
);
COMMENT ON TABLE sm.contrato_manutencao IS 'Contratos de serviço com SLA corrido, em horas.';

-- Atendimento técnico e prazo de SLA congelado na abertura.
CREATE TABLE sm.ordem_servico (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    contrato_id bigint NOT NULL REFERENCES sm.contrato_manutencao, tecnico_id bigint REFERENCES rh.colaborador, descricao text NOT NULL, aberta_em timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, prazo_em timestamptz NOT NULL, concluida_em timestamptz, status text NOT NULL DEFAULT 'ABERTA' CHECK (status IN ('ABERTA','EM_ATENDIMENTO','CONCLUIDA')), CHECK (prazo_em > aberta_em), CHECK ((status='CONCLUIDA') = (concluida_em IS NOT NULL)), CHECK (concluida_em IS NULL OR concluida_em >= aberta_em)
);
COMMENT ON TABLE sm.ordem_servico IS 'Atendimento técnico e prazo de SLA congelado na abertura.';

-- Agenda de visitas técnicas.
CREATE TABLE sm.agendamento (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ordem_servico_id bigint NOT NULL REFERENCES sm.ordem_servico, tecnico_id bigint NOT NULL REFERENCES rh.colaborador, inicio timestamptz NOT NULL, fim timestamptz NOT NULL, CHECK (fim > inicio)
);
COMMENT ON TABLE sm.agendamento IS 'Agenda de visitas técnicas.';

-- Registro de riscos com probabilidade e impacto.
CREATE TABLE grc.risco (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    descricao text NOT NULL, responsavel_id bigint NOT NULL REFERENCES sys.usuario, probabilidade smallint NOT NULL CHECK (probabilidade BETWEEN 1 AND 5), impacto smallint NOT NULL CHECK (impacto BETWEEN 1 AND 5), tratamento text NOT NULL
);
COMMENT ON TABLE grc.risco IS 'Registro de riscos com probabilidade e impacto.';

-- Controles associados aos riscos.
CREATE TABLE grc.controle (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    risco_id bigint NOT NULL REFERENCES grc.risco, descricao text NOT NULL, periodicidade_dias integer NOT NULL CHECK (periodicidade_dias > 0), proxima_revisao date NOT NULL
);
COMMENT ON TABLE grc.controle IS 'Controles associados aos riscos.';

-- Evidências e resultados das verificações de controles.
CREATE TABLE grc.auditoria_interna (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    controle_id bigint NOT NULL REFERENCES grc.controle, auditor_id bigint NOT NULL REFERENCES sys.usuario, data date NOT NULL, resultado text NOT NULL CHECK (resultado IN ('CONFORME','NAO_CONFORME')), evidencia text NOT NULL
);
COMMENT ON TABLE grc.auditoria_interna IS 'Evidências e resultados das verificações de controles.';

-- Solicitações dos titulares para o processo de privacidade; não executa exclusões automáticas.
CREATE TABLE grc.solicitacao_privacidade (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parceiro_id bigint REFERENCES cad.parceiro, tipo text NOT NULL CHECK (tipo IN ('ACESSO','CORRECAO','EXCLUSAO')), recebida_em timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, status text NOT NULL DEFAULT 'PENDENTE' CHECK (status IN ('PENDENTE','EM_ANALISE','ATENDIDA','INDEFERIDA')), justificativa text
);
COMMENT ON TABLE grc.solicitacao_privacidade IS 'Solicitações dos titulares para o processo de privacidade; não executa exclusões automáticas.';

-- Plano de inspeção por produto.
CREATE TABLE qm.plano_amostragem (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    produto_id bigint NOT NULL REFERENCES mm.produto, nome text NOT NULL, tamanho_amostra integer NOT NULL CHECK (tamanho_amostra > 0), max_defeitos integer NOT NULL CHECK (max_defeitos >= 0 AND max_defeitos <= tamanho_amostra)
);
COMMENT ON TABLE qm.plano_amostragem IS 'Plano de inspeção por produto.';

-- Rastreabilidade documental de lotes; estoque desta versão é agregado por produto/depósito.
CREATE TABLE qm.lote (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    produto_id bigint NOT NULL REFERENCES mm.produto, codigo text NOT NULL, compra_id bigint REFERENCES mm.compra, ordem_producao_id bigint REFERENCES pp.ordem, fabricacao date NOT NULL, validade date, CHECK (validade IS NULL OR validade >= fabricacao), CHECK (num_nonnulls(compra_id,ordem_producao_id) <= 1), UNIQUE(produto_id,codigo)
);
COMMENT ON TABLE qm.lote IS 'Rastreabilidade documental de lotes; estoque desta versão é agregado por produto/depósito.';

-- Inspeções de recebimento, produção e expedição.
CREATE TABLE qm.inspecao (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lote_id bigint NOT NULL REFERENCES qm.lote, plano_id bigint NOT NULL REFERENCES qm.plano_amostragem, etapa text NOT NULL CHECK (etapa IN ('RECEBIMENTO','PRODUCAO','EXPEDICAO')), inspecionada_em timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, defeitos integer NOT NULL CHECK (defeitos >= 0), resultado text NOT NULL CHECK (resultado IN ('APROVADO','REPROVADO'))
);
COMMENT ON TABLE qm.inspecao IS 'Inspeções de recebimento, produção e expedição.';

-- Ocorrências de qualidade e ações corretivas.
CREATE TABLE qm.nao_conformidade (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    inspecao_id bigint NOT NULL REFERENCES qm.inspecao, descricao text NOT NULL, acao_corretiva text, resolvida_em timestamptz
);
COMMENT ON TABLE qm.nao_conformidade IS 'Ocorrências de qualidade e ações corretivas.';

-- Bens patrimoniais; depreciação linear mensal sem cálculo tributário.
CREATE TABLE am.ativo (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    filial_id bigint NOT NULL REFERENCES cad.filial, patrimonio text NOT NULL UNIQUE, descricao text NOT NULL, aquisicao date NOT NULL, valor_aquisicao numeric(16,2) NOT NULL CHECK (valor_aquisicao > 0), valor_residual numeric(16,2) NOT NULL DEFAULT 0 CHECK (valor_residual >= 0 AND valor_residual <= valor_aquisicao), vida_util_meses integer NOT NULL CHECK (vida_util_meses > 0)
);
COMMENT ON TABLE am.ativo IS 'Bens patrimoniais; depreciação linear mensal sem cálculo tributário.';

-- Quotas mensais únicas, limitadas ao valor depreciável.
CREATE TABLE am.depreciacao (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ativo_id bigint NOT NULL REFERENCES am.ativo, competencia date NOT NULL CHECK (extract(day FROM competencia)=1), valor numeric(16,2) NOT NULL CHECK (valor > 0), UNIQUE(ativo_id,competencia)
);
COMMENT ON TABLE am.depreciacao IS 'Quotas mensais únicas, limitadas ao valor depreciável.';

-- Histórico de laudos de reavaliação; não altera automaticamente a base de depreciação.
CREATE TABLE am.reavaliacao (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ativo_id bigint NOT NULL REFERENCES am.ativo, data date NOT NULL, valor_avaliado numeric(16,2) NOT NULL CHECK (valor_avaliado >= 0), laudo text NOT NULL
);
COMMENT ON TABLE am.reavaliacao IS 'Histórico de laudos de reavaliação; não altera automaticamente a base de depreciação.';

-- Manutenções preventivas e corretivas dos ativos.
CREATE TABLE am.manutencao (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ativo_id bigint NOT NULL REFERENCES am.ativo, tipo text NOT NULL CHECK (tipo IN ('PREVENTIVA','CORRETIVA')), prevista_para date NOT NULL, realizada_em date, custo numeric(16,2) CHECK (custo >= 0), descricao text NOT NULL
);
COMMENT ON TABLE am.manutencao IS 'Manutenções preventivas e corretivas dos ativos.';

-- Catálogo de tributos; alíquotas dependem de parametrização e validação especializada.
CREATE TABLE fiscal.tributo (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo text NOT NULL UNIQUE, nome text NOT NULL
);
COMMENT ON TABLE fiscal.tributo IS 'Catálogo de tributos; alíquotas dependem de parametrização e validação especializada.';
CREATE SEQUENCE fiscal.numero_documento_seq START WITH 1;

-- Documento INTERNO de faturamento; não equivale a NF-e autorizada pela SEFAZ.
CREATE TABLE fiscal.documento (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pedido_id bigint NOT NULL UNIQUE REFERENCES sd.pedido, numero bigint NOT NULL DEFAULT nextval('fiscal.numero_documento_seq') UNIQUE, emitido_em timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, valor numeric(16,2) NOT NULL CHECK (valor > 0), chave_autorizada varchar(44) UNIQUE CHECK (chave_autorizada ~ '^[0-9]{44}$'), status text NOT NULL DEFAULT 'INTERNO' CHECK (status IN ('INTERNO','AUTORIZADO','REJEITADO')), CHECK (status <> 'AUTORIZADO' OR chave_autorizada IS NOT NULL)
);
COMMENT ON TABLE fiscal.documento IS 'Documento INTERNO de faturamento; não equivale a NF-e autorizada pela SEFAZ.';

-- Bases e valores informados da apuração fiscal.
CREATE TABLE fiscal.documento_tributo (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    documento_id bigint NOT NULL REFERENCES fiscal.documento, tributo_id bigint NOT NULL REFERENCES fiscal.tributo, base numeric(16,2) NOT NULL CHECK (base >= 0), aliquota numeric(7,4) NOT NULL CHECK (aliquota BETWEEN 0 AND 100), valor numeric(16,2) GENERATED ALWAYS AS (round(base * aliquota / 100,2)) STORED, UNIQUE(documento_id,tributo_id)
);
COMMENT ON TABLE fiscal.documento_tributo IS 'Bases e valores informados da apuração fiscal.';

-- Controle de processamento e protocolo de SPED, EFD e eSocial externos.
CREATE TABLE fiscal.obrigacao (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tipo text NOT NULL CHECK (tipo IN ('SPED','EFD','ESOCIAL')), competencia date NOT NULL CHECK (extract(day FROM competencia)=1), filial_id bigint NOT NULL REFERENCES cad.filial, status text NOT NULL DEFAULT 'PENDENTE' CHECK (status IN ('PENDENTE','GERADA','ENVIADA','ACEITA','REJEITADA')), protocolo text, UNIQUE(tipo,competencia,filial_id)
);
COMMENT ON TABLE fiscal.obrigacao IS 'Controle de processamento e protocolo de SPED, EFD e eSocial externos.';

-- Vínculo de identidade do portal ao cliente, fornecedor ou colaborador; autorização deve ser aplicada pela API.
CREATE TABLE portal.vinculo (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_id bigint NOT NULL REFERENCES sys.usuario, cliente_id bigint REFERENCES cad.cliente, fornecedor_id bigint REFERENCES cad.fornecedor, colaborador_id bigint REFERENCES rh.colaborador, CHECK (num_nonnulls(cliente_id,fornecedor_id,colaborador_id)=1), UNIQUE NULLS NOT DISTINCT(usuario_id,cliente_id,fornecedor_id,colaborador_id)
);
COMMENT ON TABLE portal.vinculo IS 'Vínculo de identidade do portal ao cliente, fornecedor ou colaborador; autorização deve ser aplicada pela API.';

-- Mensagens persistidas para o portal/mobile; entrega push é responsabilidade externa.
CREATE TABLE portal.notificacao (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_id bigint NOT NULL REFERENCES sys.usuario, titulo text NOT NULL, mensagem text NOT NULL, criada_em timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, lida_em timestamptz, CHECK (lida_em IS NULL OR lida_em >= criada_em)
);
COMMENT ON TABLE portal.notificacao IS 'Mensagens persistidas para o portal/mobile; entrega push é responsabilidade externa.';

-- Metadados de conectores; credenciais ficam em cofre externo.
CREATE TABLE api.conector (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome text NOT NULL UNIQUE, tipo text NOT NULL CHECK (tipo IN ('BANCO','MARKETPLACE','TRANSPORTADORA','LEGADO','IOT','IA','BLOCKCHAIN')), endpoint text NOT NULL, ativo boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE api.conector IS 'Metadados de conectores; credenciais ficam em cofre externo.';

-- Eventos transacionais para publicação por worker; consumidor deve deduplicar pelo ID.
CREATE TABLE api.outbox (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tipo text NOT NULL, agregado text NOT NULL, agregado_id bigint NOT NULL, payload jsonb NOT NULL CHECK (jsonb_typeof(payload)='object'), criado_em timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, publicado_em timestamptz, tentativas integer NOT NULL DEFAULT 0 CHECK (tentativas >= 0)
);
COMMENT ON TABLE api.outbox IS 'Eventos transacionais para publicação por worker; consumidor deve deduplicar pelo ID.';

-- Deduplicação de eventos externos por conector e chave.
CREATE TABLE api.inbox (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    conector_id bigint NOT NULL REFERENCES api.conector, chave_externa text NOT NULL, recebido_em timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, payload jsonb NOT NULL, processado_em timestamptz, UNIQUE(conector_id,chave_externa)
);
COMMENT ON TABLE api.inbox IS 'Deduplicação de eventos externos por conector e chave.';

-- Sensores associados a centros produtivos.
CREATE TABLE api.sensor (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    conector_id bigint NOT NULL REFERENCES api.conector, centro_trabalho_id bigint NOT NULL REFERENCES pp.centro_trabalho, codigo text NOT NULL UNIQUE, grandeza text NOT NULL, unidade text NOT NULL
);
COMMENT ON TABLE api.sensor IS 'Sensores associados a centros produtivos.';

-- Resultados de modelos externos de IA; não treina modelos no banco.
CREATE TABLE api.previsao_demanda (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    produto_id bigint NOT NULL REFERENCES mm.produto, data_referencia date NOT NULL, modelo text NOT NULL, quantidade numeric(16,3) NOT NULL CHECK (quantidade >= 0), gerada_em timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP, UNIQUE(produto_id,data_referencia,modelo)
);
COMMENT ON TABLE api.previsao_demanda IS 'Resultados de modelos externos de IA; não treina modelos no banco.';

-- Referência externa para ancoragem de hashes; não implementa uma blockchain.
CREATE TABLE api.ancora_blockchain (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    contrato_id bigint NOT NULL REFERENCES sd.contrato, hash_sha256 char(64) NOT NULL CHECK (hash_sha256 ~ '^[0-9a-f]{64}$'), rede text NOT NULL, transacao_externa text NOT NULL UNIQUE, registrada_em timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE api.ancora_blockchain IS 'Referência externa para ancoragem de hashes; não implementa uma blockchain.';

-- Auditoria particionada anualmente; a partição DEFAULT evita falhas fora do intervalo.
-- Guarda identidade e nomes dos campos, não copia salários, documentos ou segredos.
CREATE TABLE grc.evento_auditoria (
    id bigint GENERATED ALWAYS AS IDENTITY,
    ocorrido_em timestamptz NOT NULL DEFAULT clock_timestamp(),
    usuario_banco name NOT NULL, papel_ativo text NOT NULL,
    tabela text NOT NULL, operacao text NOT NULL, registro_id bigint,
    campos text[] NOT NULL, transacao bigint NOT NULL,
    PRIMARY KEY (ocorrido_em,id)
) PARTITION BY RANGE (ocorrido_em);
CREATE TABLE grc.evento_auditoria_2026 PARTITION OF grc.evento_auditoria
    FOR VALUES FROM ('2026-01-01 00:00:00+00') TO ('2027-01-01 00:00:00+00');
CREATE TABLE grc.evento_auditoria_2027 PARTITION OF grc.evento_auditoria
    FOR VALUES FROM ('2027-01-01 00:00:00+00') TO ('2028-01-01 00:00:00+00');
CREATE TABLE grc.evento_auditoria_demais PARTITION OF grc.evento_auditoria DEFAULT;
CREATE INDEX ON grc.evento_auditoria (tabela,registro_id,ocorrido_em DESC);
CREATE INDEX ON grc.evento_auditoria USING brin (ocorrido_em);

-- Telemetria é semiestruturada em JSONB, no próprio PostgreSQL.
-- MongoDB/Redis/Data Lake podem ser conectados posteriormente, não estão instalados.
CREATE TABLE api.telemetria (
    sensor_id bigint NOT NULL REFERENCES api.sensor,
    medido_em timestamptz NOT NULL,
    valor numeric NOT NULL,
    atributos jsonb NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (medido_em,sensor_id)
) PARTITION BY RANGE(medido_em);
CREATE TABLE api.telemetria_2026 PARTITION OF api.telemetria
    FOR VALUES FROM ('2026-01-01 00:00:00+00') TO ('2027-01-01 00:00:00+00');
CREATE TABLE api.telemetria_demais PARTITION OF api.telemetria DEFAULT;
CREATE INDEX ON api.telemetria (sensor_id,medido_em DESC);
CREATE INDEX ON api.telemetria USING gin (atributos);


-- Completa índices das FKs sem duplicar índices cujo prefixo já cobre a relação.
DO $$
DECLARE r record;
BEGIN
 FOR r IN
 SELECT c.conrelid::regclass AS tabela, c.conname,
        string_agg(quote_ident(a.attname), ',' ORDER BY k.ord) AS colunas
 FROM pg_constraint c
 JOIN pg_class tab ON tab.oid=c.conrelid
 JOIN pg_namespace ns ON ns.oid=tab.relnamespace
 CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY k(attnum,ord)
 JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum
 WHERE c.contype='f' AND ns.nspname = ANY (ARRAY['cad','sys','fi','rh','mm','sd','pp','ps','sm','grc','qm','am','fiscal','portal','api'])
 AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=c.conrelid
                 AND i.indpred IS NULL AND i.indisvalid
                 AND (i.indkey::smallint[])[0:cardinality(c.conkey)-1] @> c.conkey)
 GROUP BY c.conrelid,c.conname
 LOOP
   EXECUTE format('CREATE INDEX %I ON %s (%s)', 'ix_'||r.conname,r.tabela,r.colunas);
 END LOOP;
END $$;
CREATE INDEX ix_titulo_vencimento ON fi.titulo (vencimento,tipo);
CREATE INDEX ix_movimento_produto_data ON mm.movimento (produto_id,deposito_id,criado_em DESC);
CREATE INDEX ix_outbox_pendente ON api.outbox (id) WHERE publicado_em IS NULL;
CREATE INDEX ix_pedido_aberto ON sd.pedido (cliente_id) WHERE status='ABERTO';
CREATE INDEX ix_servico_prazo ON sm.ordem_servico (prazo_em) WHERE status <> 'CONCLUIDA';
