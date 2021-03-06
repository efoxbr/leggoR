#' @title Processa a proposição
#' @description Realiza todas os processamentos necessários para criar
#' as tabelas para uma proposição
#' @param id Id da proposição
#' @param casa senado ou camara
#' @param agenda dataframe com a agenda
#' @return list com os dataframes: proposicao, fases_eventos,
#' hist_temperatura e emendas
process_etapa <- function(id, casa, agenda, pautas) {
  prop <- agoradigital::fetch_proposicao(id, casa)
  tram <- agoradigital::fetch_tramitacao(id, casa)
  proc_tram <-
    agoradigital::process_proposicao(prop, tram, casa) %>%
    dplyr::mutate(data_hora = as.POSIXct(data_hora))
  status <- agoradigital::extract_status_tramitacao(id, casa)
  historico_temperatura <-
    agoradigital::get_historico_temperatura_recente(eventos_df = proc_tram, pautas = pautas) %>%
    dplyr::mutate(id_ext = prop$prop_id, casa = prop$casa) %>%
    dplyr::select(id_ext, casa, periodo, temperatura_periodo, temperatura_recente)
  temperatura_value <-
    historico_temperatura %>%
    dplyr::slice(dplyr::n()) %>%
    .$temperatura_recente
  extended_prop <-
    merge(prop, status, by = "prop_id") %>%
    dplyr::mutate(temperatura = temperatura_value)
  emendas <- rcongresso::fetch_emendas(id, casa, extended_prop$sigla_tipo, extended_prop$numero, extended_prop$ano)

  list(
    proposicao = extended_prop,
    fases_eventos = proc_tram,
    hist_temperatura = historico_temperatura,
    emendas = emendas
    )
}

#' @title Adiciona uma coluna para indicar se a proposição pulou alguma fase
#' @description Verifica se a proposição pulou uma fase
#' @param progresso_df DataFrame com o progresso da tramitação
#' @return Dataframe
adiciona_coluna_pulou <- function(progresso_df) {
  progresso_df$prox_local_casa = dplyr::lead(progresso_df$local_casa)

  progresso_df %>%
    dplyr::mutate(
      pulou = dplyr::if_else((is.na(local_casa) & !is.na(prox_local_casa)), T, F)) %>%
    dplyr::select(-prox_local_casa)
}

#' @title Adiciona locais
#' @description Adiciona locais faltantes ao progresso
#' @param progresso_df DataFrame com o progresso da tramitação
#' @return Dataframe
adiciona_locais_faltantes_progresso <- function(progresso_df) {
  progresso_df %>%
    dplyr::mutate(local_casa = dplyr::case_when(
      local %in% c('Presidência da República', 'Congresso') ~
        tolower(local),
      (fase_global == "Revisão I" & is.na(local_casa)) ~ ifelse(.$casa[[1]] == 'senado', 'camara', 'senado'),
      fase_global == "Revisão II" ~ .$casa[[1]],
      is.na(local_casa) ~ casa,
      TRUE ~ local_casa))
}

#' @title Adiciona o status da proposição
#' @description Verifica se a proposição esta Ativa, Arquivada ou virou Lei
#' @param tramitacao_df DataFrame com a tramitacao depois de ser processada pelo process_pl
#' @return Dataframe
adiciona_status <- function(tramitacao_df) {
  tramitacao_df %>%
    dplyr::group_by(id_ext, casa) %>%
    dplyr::mutate(status = dplyr::case_when(evento == "arquivamento" ~ "Arquivada",
                                                        evento == "desarquivamento" ~ "Ativa",
                                                        dplyr::lead(evento, order_by = data) == "transformada_lei" ~ "Lei")) %>%
    tidyr::fill(status) %>%
    dplyr::mutate(status = dplyr::case_when(is.na(status) ~ "Ativa",
                  T ~ status))
}

#' @title Gera etapas
#' @description Gera a lista etapas com todas as tabelas necessárias para o back
#' @param row_num Row number da proposição na tabela
#' @param id_camara Id da proposição na camara
#' @param id_senado Id da proposição no senado
#' @param apelido Apelido da proposição
#' @param tema_pl Tema da proposição
#' @param agenda Agenda
#' @param total_rows número de linhas da tabela com os ids das proposições
#' @return Dataframe
process_pl <- function(row_num, id_camara, id_senado, apelido, tema_pl, agenda, total_rows, pautas) {
  # cat(paste(
  #   "\n--- Processando",row_num,"/",total_rows,":", apelido, "\ncamara:", id_camara,
  #   "\nsenado", id_senado, "\n"))
  etapas <- list()
  if (!is.na(id_camara)) {
    etapas %<>% append(list(process_etapa(id_camara, "camara", agenda, pautas = pautas)))
  }
  if (!is.na(id_senado)) {
    etapas %<>% append(list(process_etapa(id_senado, "senado", agenda, pautas = pautas)))
  }
  etapas %<>% purrr::pmap(dplyr::bind_rows)
  etapas[["progresso"]] <-
    agoradigital::get_progresso(etapas$proposicao, etapas$fases_eventos) %>%
    adiciona_coluna_pulou() %>%
    adiciona_locais_faltantes_progresso()
  etapas$proposicao %<>%
    dplyr::mutate(apelido_materia = apelido, tema = tema_pl)
  etapas
}

#' @title Exporta dados de proposições
#' @description Exporta para uma pasta CSVs com dados sobre uma lista de proposições.
#' @param pls dataframe com proposições.
#' @param export_path pasta para onde exportar dados.
#' @export
export_data <- function(pls, export_path) {
  # agenda <- fetch_agenda_geral(as.Date(cut(Sys.Date(), "week")), as.Date(cut(Sys.Date(), "week")) + 4)
  agenda <- tibble::as_tibble()
  pautas <- tibble::tribble(~data, ~sigla, ~id_ext, ~local, ~casa, ~semana, ~ano)
  tryCatch({
    pautas <- readr::read_csv(paste0(export_path, "pautas.csv"))
  },
  error = function(msg) {
  })

  res <- pls %>% purrr::pmap(process_pl, agenda, nrow(pls), pautas = pautas)
  proposicoes <-
    purrr::map_df(res, ~ .$proposicao) %>%
    dplyr::select(-c(status_proposicao_sigla_orgao, ano)) %>%
    dplyr::rename(id_ext = prop_id, apelido = apelido_materia)
  tramitacoes <-
    purrr::map_df(res, ~ .$fases_eventos) %>%
    dplyr::rename(id_ext = prop_id, data = data_hora) %>%
    adiciona_status()
  tramitacoes_que_viraram_lei <-
    tramitacoes %>%
    dplyr::filter(evento == "transformada_lei")
  tramitacoes <-
    tramitacoes %>%
    dplyr::filter(!(id_ext %in% tramitacoes_que_viraram_lei$id_ext))
  hists_temperatura <- purrr::map_df(res, ~ .$hist_temperatura)
  progressos <-
    purrr::map_df(res, ~ .$progresso) %>%
    dplyr::rename(id_ext = prop_id)
  emendas <-
    purrr::map_df(res, ~ .$emendas) %>%
    dplyr::rename(id_ext = prop_id)
  comissoes <-
    agoradigital::fetch_all_composicao_comissao() %>% 
    dplyr::rename(id_parlamentar = id)

  ## export data to CSVs
  readr::write_csv(proposicoes, paste0(export_path, "/proposicoes.csv"))
  readr::write_csv(tramitacoes, paste0(export_path, "/trams.csv"))
  readr::write_csv(
    hists_temperatura, paste0(export_path, "/hists_temperatura.csv"))
  readr::write_csv(progressos, paste0(export_path, "/progressos.csv"))
  readr::write_csv(emendas, paste0(export_path, "/emendas.csv"))
  readr::write_csv(comissoes, paste0(export_path, "/comissoes.csv"))
}
