-- ERP ACADÊMICO EM POSTGRESQL 17+ | INSTALAÇÃO COMPLETA COMENTADA
-- 1. Crie um banco vazio chamado erp_academico no pgAdmin ou com CREATE DATABASE.
-- 2. Conecte-se a ELE como administrador/superusuário e execute este arquivo inteiro.
-- 3. Execute dados_demonstracao.sql e depois consultas_demonstracao.sql.
-- A instalação é atômica, não usa DROP e não deve ser repetida no mesmo banco.
-- Este arquivo consolida V001 a V007. Não execute os dois caminhos na mesma base.
-- Alternativa: Flyway usando a pasta migrations/ em banco vazio, como administrador.
-- Dados da demonstração e testes são opcionais e NÃO entram em produção.
-- Não contém senhas de usuários. Identidades funcionais são NOLOGIN.
-- Modelos ER, relatório e demais documentos acadêmicos ficam para a próxima etapa.
BEGIN;
SET LOCAL TIME ZONE 'America/Sao_Paulo';
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

COMMIT;
