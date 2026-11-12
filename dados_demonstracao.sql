-- Dados FICTÍCIOS para apresentação. Execute uma única vez, após a instalação.
-- O bloco inteiro é atômico; IDs são obtidos por RETURNING, sem depender de sequências iniciadas em 1.
-- O papel DBA é proprietário; não é preciso criar usuários/senhas de demonstração.
BEGIN;
SET LOCAL ROLE erp_dba;
DO $$
#variable_conflict use_variable
DECLARE f bigint; cc bigint; cliente bigint; fornecedor bigint; parceiro_c bigint; parceiro_f bigint;
 u bigint; u2 bigint; cargo bigint; col bigint; col2 bigint; beneficio bigint; folha bigint; vaga bigint;
 banco bigint; dep bigint; dep2 bigint; madeira bigint; cadeira bigint; parafuso bigint;
 compra bigint; pedido bigint; contrato bigint; oportunidade bigint; ct bigint; op bigint;
 projeto bigint; tarefa bigint; aloc bigint; manut bigint; os bigint; risco bigint; controle bigint;
 plano bigint; lote bigint; inspecao bigint; ativo bigint; conector bigint; sensor bigint; inv bigint; titulo bigint; baixa bigint; extrato bigint; doc bigint;
BEGIN
 INSERT INTO cad.filial(nome,cnpj) VALUES('Fábrica Escola - Matriz','00000000000100') RETURNING id INTO f;
 INSERT INTO cad.centro_custo(filial_id,codigo,nome) VALUES(f,'CC-001','Produção e administração') RETURNING id INTO cc;
 INSERT INTO cad.parceiro(nome,documento,email) VALUES('Cliente Demonstração','00000000000200','cliente@example.invalid') RETURNING id INTO parceiro_c;
 INSERT INTO cad.parceiro(nome,documento,email) VALUES('Fornecedor Demonstração','00000000000300','fornecedor@example.invalid') RETURNING id INTO parceiro_f;
 INSERT INTO cad.cliente(parceiro_id,limite_credito) VALUES(parceiro_c,10000) RETURNING id INTO cliente;
 INSERT INTO cad.fornecedor(parceiro_id,prazo_dias) VALUES(parceiro_f,30) RETURNING id INTO fornecedor;
 INSERT INTO sys.usuario(login,nome,identidade_externa) VALUES('demo.gestora','Gestora Fictícia','demo:gestora') RETURNING id INTO u;
 INSERT INTO sys.usuario(login,nome,identidade_externa) VALUES('demo.tecnico','Técnico Fictício','demo:tecnico') RETURNING id INTO u2;
 INSERT INTO sys.usuario_perfil(usuario_id,perfil_id) SELECT u,id FROM sys.perfil WHERE nome='CEO';
 INSERT INTO rh.cargo(nome,salario_referencia) VALUES('Analista demonstrativo',4000) RETURNING id INTO cargo;
 INSERT INTO rh.colaborador(filial_id,centro_custo_id,cargo_id,usuario_id,matricula,nome,admissao,salario_base)
 VALUES(f,cc,cargo,u,'DEMO-001','Ana Exemplo',CURRENT_DATE-365,4000) RETURNING id INTO col;
 INSERT INTO rh.colaborador(filial_id,centro_custo_id,cargo_id,usuario_id,matricula,nome,admissao,salario_base)
 VALUES(f,cc,cargo,u2,'DEMO-002','Bruno Exemplo',CURRENT_DATE-180,4000) RETURNING id INTO col2;
 INSERT INTO rh.beneficio(nome,valor_padrao) VALUES('Vale alimentação demonstrativo',500) RETURNING id INTO beneficio;
 INSERT INTO rh.colaborador_beneficio(colaborador_id,beneficio_id,inicio,valor) VALUES(col,beneficio,CURRENT_DATE-30,500);
 INSERT INTO rh.ponto(colaborador_id,entrada,saida) VALUES(col,CURRENT_DATE+time '08:00',CURRENT_DATE+time '12:00');
 INSERT INTO rh.folha(filial_id,competencia) VALUES(f,date_trunc('month',CURRENT_DATE)::date) RETURNING id INTO folha;
 INSERT INTO rh.folha_item(folha_id,colaborador_id,rubrica_id,valor) SELECT folha,col,id,4000 FROM rh.rubrica WHERE codigo='SALARIO';
 INSERT INTO rh.folha_item(folha_id,colaborador_id,rubrica_id,valor) SELECT folha,col,id,400 FROM rh.rubrica WHERE codigo='DESCONTO';
 CALL rh.fechar_folha(folha);
 INSERT INTO rh.vaga(filial_id,cargo_id,titulo,status) VALUES(f,cargo,'Analista de produção','ABERTA') RETURNING id INTO vaga;
 INSERT INTO rh.candidatura(vaga_id,nome,email,etapa) VALUES(vaga,'Candidato Exemplo','candidato@example.invalid','ENTREVISTA');
 INSERT INTO rh.avaliacao(colaborador_id,avaliador_id,data,nota,observacao) VALUES(col2,col,CURRENT_DATE,8.5,'Avaliação fictícia');
 INSERT INTO fi.conta_bancaria(filial_id,banco,agencia,numero,conta_contabil_id)
 SELECT f,'Banco Simulado','0001','DEMO',id FROM fi.conta_contabil WHERE codigo='1.01' RETURNING id INTO banco;
 INSERT INTO fi.orcamento(centro_custo_id,conta_id,competencia,valor)
 SELECT cc,id,date_trunc('month',CURRENT_DATE)::date,10000 FROM fi.conta_contabil WHERE codigo='4.01';
 INSERT INTO mm.deposito(filial_id,nome) VALUES(f,'Principal') RETURNING id INTO dep;
 INSERT INTO mm.deposito(filial_id,nome) VALUES(f,'Expedição') RETURNING id INTO dep2;
 INSERT INTO mm.produto(sku,nome,unidade,tipo,preco_venda,estoque_minimo) VALUES('MP-MADEIRA','Madeira demonstrativa','UN','MATERIA_PRIMA',20,10) RETURNING id INTO madeira;
 INSERT INTO mm.produto(sku,nome,unidade,tipo,preco_venda,estoque_minimo) VALUES('MP-PARAFUSO','Parafuso demonstrativo','UN','MATERIA_PRIMA',1,50) RETURNING id INTO parafuso;
 INSERT INTO mm.produto(sku,nome,unidade,tipo,preco_venda,estoque_minimo) VALUES('PA-CADEIRA','Cadeira demonstrativa','UN','ACABADO',150,5) RETURNING id INTO cadeira;
 INSERT INTO mm.compra(fornecedor_id,deposito_id) VALUES(fornecedor,dep) RETURNING id INTO compra;
 INSERT INTO mm.compra_item(compra_id,produto_id,quantidade,custo_unitario) VALUES(compra,madeira,100,10),(compra,parafuso,400,0.5);
 CALL mm.receber_compra(compra,CURRENT_DATE+30); -- Estoque + título de R$ 1.200 + contabilidade.
 INSERT INTO pp.bom(produto_id,componente_id,quantidade) VALUES(cadeira,madeira,2),(cadeira,parafuso,4);
 INSERT INTO pp.centro_trabalho(filial_id,nome,horas_dia) VALUES(f,'Montagem',8) RETURNING id INTO ct;
 op:=pp.abrir_ordem(cadeira,dep,ct,10,CURRENT_DATE,4);
 INSERT INTO pp.apontamento(ordem_id,colaborador_id,inicio,fim,quantidade_boa,quantidade_refugo)
 VALUES(op,col2,CURRENT_TIMESTAMP-interval '4 hours',CURRENT_TIMESTAMP,10,0);
 CALL pp.concluir_ordem(op); -- Consome 20 madeiras + 40 parafusos e produz 10 cadeiras.
 INSERT INTO sd.contrato(cliente_id,numero,inicio,fim,valor) VALUES(cliente,'DEMO-C001',CURRENT_DATE-30,CURRENT_DATE+365,5000) RETURNING id INTO contrato;
 INSERT INTO sd.oportunidade(cliente_id,etapa_id,responsavel_id,descricao,valor_estimado,probabilidade)
 SELECT cliente,id,u,'Venda de mobiliário',1500,80 FROM sd.etapa_funil WHERE nome='Negociação' RETURNING id INTO oportunidade;
 INSERT INTO sd.interacao(oportunidade_id,usuario_id,descricao) VALUES(oportunidade,u,'Cliente aprovou a proposta de demonstração.');
 INSERT INTO sd.pedido(cliente_id,deposito_id,contrato_id) VALUES(cliente,dep,contrato) RETURNING id INTO pedido;
 INSERT INTO sd.pedido_item(pedido_id,produto_id,quantidade,preco_unitario,desconto) VALUES(pedido,cadeira,3,150,0);
 CALL sd.faturar_pedido(pedido,CURRENT_DATE+15); -- 3 cadeiras: receita/título de R$ 450; sobram 7.
 SELECT titulo_id INTO titulo FROM sd.pedido WHERE id=pedido;
 CALL fi.baixar_titulo(titulo,banco,200,'11111111-1111-4111-8111-111111111111'); -- Restam R$ 250.
 SELECT id INTO baixa FROM fi.baixa WHERE titulo_id=titulo;
 INSERT INTO fi.extrato(conta_bancaria_id,chave_externa,data,valor,descricao)
 VALUES(banco,'DEMO-EXTRATO-001',CURRENT_DATE,200,'Recebimento parcial') RETURNING id INTO extrato;
 INSERT INTO fi.conciliacao(extrato_id,baixa_id) VALUES(extrato,baixa);
 CALL mm.transferir(cadeira,dep,dep2,2); -- 5 no Principal; 2 na Expedição.
 INSERT INTO mm.inventario(deposito_id) VALUES(dep2) RETURNING id INTO inv;
 INSERT INTO mm.inventario_item(inventario_id,produto_id,quantidade_contada) VALUES(inv,cadeira,2);
 CALL mm.aplicar_inventario(inv); -- Contagem igual ao saldo: nenhum ajuste fictício.
 -- Uma ordem ainda aberta alimenta o relatório MRP e a análise de capacidade.
 PERFORM pp.abrir_ordem(cadeira,dep,ct,5,CURRENT_DATE+1,3);
 INSERT INTO ps.projeto(centro_custo_id,nome,responsavel_id,inicio,fim_previsto,orcamento)
 VALUES(cc,'Implantação do ERP demonstrativo',col,CURRENT_DATE,CURRENT_DATE+60,20000) RETURNING id INTO projeto;
 INSERT INTO ps.tarefa(projeto_id,nome,inicio,fim,progresso) VALUES(projeto,'Preparar banco',CURRENT_DATE,CURRENT_DATE+10,50) RETURNING id INTO tarefa;
 INSERT INTO ps.alocacao(tarefa_id,colaborador_id,horas_previstas,custo_hora) VALUES(tarefa,col,40,50) RETURNING id INTO aloc;
 INSERT INTO ps.apontamento(alocacao_id,data,horas,descricao) VALUES(aloc,CURRENT_DATE,4,'Modelagem inicial');
 INSERT INTO sm.contrato_manutencao(cliente_id,numero,inicio,fim,sla_horas,valor_mensal)
 VALUES(cliente,'DEMO-S001',CURRENT_DATE-30,CURRENT_DATE+365,24,300) RETURNING id INTO manut;
 INSERT INTO sm.ordem_servico(contrato_id,tecnico_id,descricao) VALUES(manut,col2,'Revisão de mobiliário') RETURNING id INTO os;
 INSERT INTO sm.agendamento(ordem_servico_id,tecnico_id,inicio,fim)
 VALUES(os,col2,CURRENT_TIMESTAMP+interval '2 hours',CURRENT_TIMESTAMP+interval '3 hours');
 INSERT INTO grc.risco(descricao,responsavel_id,probabilidade,impacto,tratamento)
 VALUES('Perda de dados',u,2,5,'Backup diário e teste de restauração') RETURNING id INTO risco;
 INSERT INTO grc.controle(risco_id,descricao,periodicidade_dias,proxima_revisao)
 VALUES(risco,'Restaurar backup de teste',30,CURRENT_DATE+30) RETURNING id INTO controle;
 INSERT INTO grc.auditoria_interna(controle_id,auditor_id,data,resultado,evidencia)
 VALUES(controle,u,CURRENT_DATE,'NAO_CONFORME','Exemplo didático: agendar primeira restauração.');
 INSERT INTO grc.solicitacao_privacidade(parceiro_id,tipo) VALUES(parceiro_c,'ACESSO');
 INSERT INTO qm.plano_amostragem(produto_id,nome,tamanho_amostra,max_defeitos) VALUES(cadeira,'Amostra de 5 cadeiras',5,0) RETURNING id INTO plano;
 INSERT INTO qm.lote(produto_id,codigo,ordem_producao_id,fabricacao) VALUES(cadeira,'LOTE-DEMO-001',op,CURRENT_DATE) RETURNING id INTO lote;
 INSERT INTO qm.inspecao(lote_id,plano_id,etapa,defeitos) VALUES(lote,plano,'PRODUCAO',1) RETURNING id INTO inspecao;
 INSERT INTO qm.nao_conformidade(inspecao_id,descricao,acao_corretiva) VALUES(inspecao,'Acabamento irregular na amostra','Reinspecionar o acabamento');
 INSERT INTO am.ativo(filial_id,patrimonio,descricao,aquisicao,valor_aquisicao,valor_residual,vida_util_meses)
 VALUES(f,'DEMO-AT001','Equipamento de montagem',CURRENT_DATE-90,12000,0,60) RETURNING id INTO ativo;
 CALL am.depreciar(ativo,date_trunc('month',CURRENT_DATE)::date);
 INSERT INTO am.reavaliacao(ativo_id,data,valor_avaliado,laudo) VALUES(ativo,CURRENT_DATE,11800,'Laudo fictício, sem alteração da base');
 INSERT INTO am.manutencao(ativo_id,tipo,prevista_para,descricao) VALUES(ativo,'PREVENTIVA',CURRENT_DATE+30,'Inspeção periódica');
 SELECT id INTO doc FROM fiscal.documento WHERE pedido_id=pedido;
 -- Alíquota ZERO na demonstração: não presume enquadramento tributário.
 INSERT INTO fiscal.documento_tributo(documento_id,tributo_id,base,aliquota) SELECT doc,id,450,0 FROM fiscal.tributo WHERE codigo='ICMS';
 INSERT INTO fiscal.obrigacao(tipo,competencia,filial_id) VALUES('SPED',date_trunc('month',CURRENT_DATE)::date,f);
 INSERT INTO portal.vinculo(usuario_id,colaborador_id) VALUES(u,col);
 INSERT INTO portal.notificacao(usuario_id,titulo,mensagem) VALUES(u,'Demonstração pronta','Compra, produção, venda e baixa parcial concluídas.');
 INSERT INTO api.conector(nome,tipo,endpoint) VALUES('Sensor simulado','IOT','https://example.invalid/iot') RETURNING id INTO conector;
 INSERT INTO api.sensor(conector_id,centro_trabalho_id,codigo,grandeza,unidade) VALUES(conector,ct,'DEMO-TEMP-001','Temperatura','C') RETURNING id INTO sensor;
 INSERT INTO api.telemetria(sensor_id,medido_em,valor,atributos) VALUES(sensor,CURRENT_TIMESTAMP,25.5,'{"origem":"simulacao"}');
 INSERT INTO api.inbox(conector_id,chave_externa,payload,processado_em) VALUES(conector,'DEMO-EVT-001','{"simulado":true}',CURRENT_TIMESTAMP);
 INSERT INTO api.previsao_demanda(produto_id,data_referencia,modelo,quantidade) VALUES(cadeira,CURRENT_DATE+30,'exemplo-manual-sem-treinamento',20);
 -- Registro marcado como SIMULACAO: não há transação real em uma rede blockchain.
 INSERT INTO api.ancora_blockchain(contrato_id,hash_sha256,rede,transacao_externa)
 VALUES(contrato,encode(extensoes.digest('contrato demonstrativo','sha256'),'hex'),'SIMULACAO','demo:tx:001');
END $$;
CALL bi.atualizar_indicadores();
COMMIT;
