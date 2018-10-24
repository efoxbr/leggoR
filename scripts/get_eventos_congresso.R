library(magrittr)

url_eventos_camara <- "https://dadosabertos.camara.leg.br/api/v2/referencias/tiposTramitacao"
eventos_camara <- jsonlite::fromJSON(url_eventos_camara, flatten = T)$dados %>%
  dplyr::mutate(id = as.integer(id)) %>%
  dplyr::arrange(id)

eventos_camara %>%
  readr::write_csv('data/eventos_camara.csv')

url_eventos_senado <- "http://legis.senado.gov.br/dadosabertos/materia/situacoes"
eventos_senado <- jsonlite::fromJSON(url_eventos_senado, flatten = T)$ListaSituacoes$Situacoes$Situacao %>%
  dplyr::mutate(Codigo = as.integer(Codigo)) %>%
  dplyr::arrange(Codigo)

eventos_senado %>%
  readr::write_csv('data/eventos_senado.csv')
