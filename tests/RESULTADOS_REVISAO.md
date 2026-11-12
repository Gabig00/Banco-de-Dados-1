# Resultado da revisão técnica — 11/11/2026

Execução real em PostgreSQL 17.11, com bancos isolados e dados fictícios. Nenhum teste foi executado no computador do usuário.

| Verificação | Resultado |
|---|---|
| Instalação completa da revisão 2 | Aprovada |
| Atualização da versão anterior por V007 | Aprovada |
| Comparação dos dados e sequências antes/depois da atualização | Idênticos |
| Migração diante de um saldo `NaN` preexistente | Recusada; alterações de estrutura revertidas |
| 56 testes originais de integração | Aprovados |
| 56 testes adicionais de regressão/permissões | Aprovados |
| As mesmas 112 verificações na instalação nova | Aprovadas |
| As mesmas 112 verificações na base atualizada | Aprovadas |
| Backup completo e restauração em terceiro banco | Aprovados |
| As mesmas 112 verificações depois da restauração e reaplicação do RBAC | Aprovadas |
| Venda concorrente disputando o mesmo estoque | Uma confirma, outra falha sem estoque negativo |
| Pagamento concorrente com a mesma chave idempotente | Uma única baixa registrada |
| Mais seis disputas concorrentes, repetidas três vezes | Todas aprovadas: 18 execuções |
| 200 operações determinísticas variadas de compra, venda e transferência | 180 aceitas e 20 recusadas corretamente |
| Comparações de saldo dessas operações com modelo independente em Python/Decimal | 400 comparações corretas |
| Reconciliação final de saldo com movimentos | Correta |

As seis disputas adicionais são: recebimento duplicado de compra; pagamentos diferentes excedendo o mesmo saldo; estruturas BOM recíprocas; agendas sobrepostas; intervalos de ponto sobrepostos; depreciação simultânea da mesma competência. Foram utilizadas conexões independentes e limites de tempo para detectar travamentos.

## Falhas reproduzidas na primeira versão

1. `NaN` passava em algumas verificações numéricas e podia contaminar valores/saldos. A revisão adiciona CHECK explícito de finitude a todas as colunas NUMERIC, inclusive telemetria.
2. O prazo de SLA podia ser ampliado por UPDATE depois da abertura. Contrato, abertura e prazo agora ficam congelados; atendimento concluído não reabre.
3. Diminuir o valor de um ativo já depreciado podia produzir valor contábil negativo. Base, vida útil e aquisição ficam protegidas após a primeira quota. O cálculo também distribui centavos pelo valor acumulado e exige meses consecutivos depois da primeira quota.
4. Alterar os critérios de um plano de amostragem podia contradizer inspeções anteriores. Critérios e inspeções agora são imutáveis; novas regras exigem outro plano e nova inspeção.

## Outras correções preventivas verificadas

- Proteção de identidades estruturais de depósitos, centros, parceiros, contratos, contas bancárias e lotes.
- Validação de cronogramas tanto ao editar tarefas quanto ao editar projetos.
- Bloqueio de ciclos na hierarquia contábil e de mudanças no tipo/código/natureza de contas.
- Exclusões de BOM usam o mesmo lock da criação do snapshot da ordem.
- O perfil de operações agenda serviços sem ter permissão de atualizar nomes de colaboradores.
- Script específico de reaplicação de permissões depois da restauração, preservando as restrições da revisão 2.

As migrações V001 a V006 não foram alteradas. V007 concentra as correções; o script `atualizar_v1_para_v2.sql` a envolve em transação para atualização manual. Uma nova instalação usa `instalar.sql`, já consolidado até V007.

## Reproduzir

Em banco descartável novo, execute nesta ordem, com credenciais de administrador configuradas:

```sh
psql -X -v ON_ERROR_STOP=1 -f instalar.sql
psql -X -v ON_ERROR_STOP=1 -f dados_demonstracao.sql
psql -X -v ON_ERROR_STOP=1 -f tests/testes_integracao.sql
psql -X -v ON_ERROR_STOP=1 -f tests/testes_revisao.sql
python3 tests/testes_concorrencia.py
python3 tests/testes_estresse.py
```

Os testes Python deixam dados. Use outra cópia nova para repetir a sequência inteira. As suítes SQL revertem seus dados ao final. As execuções em três cenários repetem o mesmo conjunto de 112 verificações; não representam 336 testes distintos.

## Limites da conclusão

Os testes aumentam a confiança nas regras implementadas; não demonstram ausência de todos os defeitos. Não houve benchmark de escala empresarial, teste de failover/replicação, execução do workflow no GitHub, teste de interfaces, nem validação de serviços fiscais externos. Os limites funcionais da camada de banco continuam descritos no LEIA_ME. Uma alteração histórica já feita antes da correção pode não ser reconstruível, especialmente porque a auditoria guarda campos afetados, não todos os valores anteriores.
