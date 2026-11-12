# ERP acadêmico em PostgreSQL

Implementação da camada de banco do projeto fornecido. Nomes e comentários em português.
86 tabelas de negócio/BI (sem contar partições físicas), 16 schemas funcionais, um schema de extensões, funções, procedures, triggers, índices, views e view materializada.

## Começar pelo pgAdmin

1. Use PostgreSQL **17 ou superior**, com a extensão `pgcrypto` disponível. A validação local foi feita em **17.11**.
2. Conecte como administrador, normalmente `postgres`, e crie um banco **vazio** chamado `erp_academico`.
3. Abra o Query Tool **desse banco**, carregue `instalar.sql` e execute o arquivo inteiro. Ele instala os objetos em uma transação, sem apagar estruturas existentes.
4. Execute `dados_demonstracao.sql` uma única vez, se quiser os exemplos fictícios.
5. Abra `consultas_demonstracao.sql` e execute as consultas individualmente para apresentar os resultados.

A instalação não altera nem se conecta ao PostgreSQL do seu computador automaticamente. Os arquivos precisam ser executados na sua instância.

## Alternativa pelo terminal

Com as variáveis PGHOST, PGPORT, PGUSER e PGDATABASE configuradas e senha no `.pgpass`:

```sh
psql -X -v ON_ERROR_STOP=1 -f instalar.sql
psql -X -v ON_ERROR_STOP=1 -f dados_demonstracao.sql
psql -X -v ON_ERROR_STOP=1 -f tests/testes_integracao.sql
```

`tests/testes_integracao.sql` reverte suas alterações ao final. `tests/testes_concorrencia.py` usa duas conexões reais e **deixa dados de teste**: execute apenas em banco descartável, com uma carga nova de demonstração.

```sh
python3 tests/testes_concorrencia.py
```

Para Docker, defina `POSTGRES_PASSWORD` externamente e execute `docker compose up -d`. A instalação roda somente na criação inicial do volume. Host: `localhost`, porta: `5433`, banco: `erp_academico`, usuário: `erp_instalador`. Depois execute os dados de demonstração pelo pgAdmin ou psql. Não apague o volume para atualizar um banco com dados.

## Organização do código

- `instalar.sql`: arquivo principal, reunindo as sete migrações comentadas; funciona no Query Tool.
- `migrations/V001...V007`: alternativa de instalação/versionamento com Flyway. Não execute junto com o consolidado na mesma base. Migrações posteriores devem usar `SET ROLE erp_dba` e redefinir os GRANTs necessários. As migrações existentes são imutáveis após aplicadas.
- `dados_demonstracao.sql`: compra → produção → venda → recebimento parcial; exemplos das demais áreas.
- `consultas_demonstracao.sql`: consultas de apresentação e exemplo de EXPLAIN.
- `tests/`: validações de regras, acesso e concorrência.
- `operacao/`: backup, restauração e configuração de referência para logs/replicação.
- `.github/workflows/banco.yml`: CI para quando esta pasta for a raiz de um repositório GitHub. O workflow foi preparado; não foi executado no GitHub.

## Decisões e limites desta versão

- Uma organização com várias filiais. **Não há isolamento multitenant**. Os papéis de departamento acessam as filiais da organização.
- Papéis SQL reais: DBA, CEO, diretor, financeiro, RH, estoque, comercial, produção, operações, auditor, BI e integração. DBA possui os objetos; CEO consulta todas as áreas e executa operações autorizadas; demais perfis têm acesso restrito. Nenhum login/senha pessoal é criado. O cadastro `sys.usuario_perfil` representa o portal e não concede GRANTs automaticamente.
- Recebimento e faturamento são integrais. Não há recebimento parcial, devolução, estorno ou cancelamento de documento já finalizado. Correções desses fatos exigem uma futura rotina de reversão auditável, nunca UPDATE no histórico.
- Compras, faturamento e baixas geram partidas dobradas. O plano de contas de referência é mínimo. **Custeio de produção, CMV, avaliação monetária de estoque e contabilização automática de folha/depreciação não foram implementados**; essas extensões exigem regras de negócio adicionais. O BI mostra receita, não lucro.
- Estoque por produto/depósito, sem reserva antecipada nem bloqueio por lote/qualidade. Lotes oferecem rastreabilidade documental; não controlam o saldo físico por lote. `limite_credito` é cadastro, não bloqueio automático de venda.
- Produção congela um nível da BOM por ordem. Submontagens têm ordens próprias. MRP mostra necessidade de componentes, sem lead time, previsão de recebimentos ou cálculo de lote econômico. Capacidade é um relatório; não bloqueia agendamento produtivo.
- Folha recebe rubricas e valores informados. Não calcula INSS, IRRF, FGTS, férias ou obrigações legais. Documentos fiscais internos **não são NF-e autorizadas**; SPED, EFD e eSocial possuem controle de status, não geradores de arquivos oficiais.
- Depreciação linear com limite pelo valor residual; a competência é informada e não há scheduler. Reavaliação é histórico documental e não altera a base automaticamente.
- Portal/mobile, autenticação, conectores, push, IA e blockchain possuem estruturas de suporte. Não há aplicações, modelos treinados, envio a serviços ou transações blockchain reais. Outbox exige worker externo e consumidor idempotente.
- JSONB cobre dados semiestruturados em PostgreSQL. MongoDB, Redis, Data Lake, ELK/Splunk, réplica, cluster e balanceador **não foram implantados**. O arquivo de configuração apenas orienta a configuração futura; não comprova alta disponibilidade.
- Auditoria registra operação, identidade, ID e campos afetados; não guarda cópia dos valores anteriores. Dados sensíveis cifrados precisam de chave externa. Isso não certifica conformidade LGPD/ISO/SOX. O DBA pode alterar objetos; não há garantia de inviolabilidade contra o administrador.
- Índices foram definidos e a integridade foi testada; não houve benchmark de carga em escala empresarial. Para novas partições, trate previamente as linhas da partição DEFAULT e atualize as permissões.

Modelos conceitual/lógico, diagramas, matriz de requisitos e relatório acadêmico ficam para a próxima etapa. Este arquivo contém apenas instruções de uso e limites técnicos para não confundir a camada de banco com um ERP completo em produção.

## Referências técnicas

- https://www.postgresql.org/docs/17/ddl-priv.html
- https://www.postgresql.org/docs/17/ddl-partitioning.html
- https://www.postgresql.org/docs/17/pgcrypto.html
- https://www.postgresql.org/docs/17/app-pgdump.html

## Revisão 2: aplicar sem reinstalar

Se você já executou a primeira versão, faça backup e execute **somente `atualizar_v1_para_v2.sql`**, uma única vez, como administrador, no mesmo banco. O script preserva os dados; rejeita números especiais e alguns históricos inconsistentes em vez de corrigi-los silenciosamente. Se não instalou ainda, use `instalar.sql`, que já contém V007. Não execute os dois scripts no mesmo banco.

As migrações V001 a V006 originais foram preservadas. Usuários de Flyway aplicam apenas a nova V007 por `migrate`, sem executar o atualizador consolidado.

A revisão congela identidade de cadastros estruturais, critérios de amostragem, inspeções concluídas e o SLA de atendimentos. Para mudar os critérios, crie outro plano; para reinspecionar, registre outra inspeção. Projetos e tarefas validam seus cronogramas nos dois sentidos. Ativos não podem alterar a base após a primeira quota, e os meses de depreciação posteriores devem ser consecutivos. Centavos são distribuídos pelo alvo acumulado, podendo existir quota zero para valores muito pequenos. Planos de contas não admitem ciclos.

Alterações indevidas feitas antes da atualização nem sempre são reconstruíveis: por exemplo, um prazo de SLA adulterado não tem seu valor original armazenado. A revisão bloqueia novas alterações; não inventa histórico perdido.

Depois de restaurar um backup com `--no-owner --no-acl`, execute `operacao/reaplicar_permissoes.sql`, que reúne os GRANTs e as restrições da revisão 2. Não reaplique apenas V006: isso restauraria duas permissões removidas nesta revisão.

Testes adicionais, em banco de demonstração descartável:

```sh
psql -X -v ON_ERROR_STOP=1 -f tests/testes_revisao.sql
python3 tests/testes_estresse.py
```

Execute as duas suítes SQL antes dos testes Python. As suítes SQL fazem ROLLBACK. As suítes Python modificam dados e devem rodar uma vez por cópia nova do banco. Não confunda a carga limitada dos testes com um benchmark de capacidade empresarial.
