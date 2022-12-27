#!/usr/bin/env Rscript

suppressPackageStartupMessages(library(optparse))
suppressPackageStartupMessages(library(tidyverse))
suppressPackageStartupMessages(library(tidytext))
suppressPackageStartupMessages(library(tm))
suppressPackageStartupMessages(library(topicmodels))
suppressPackageStartupMessages(library(slam))
suppressPackageStartupMessages(library(httr))

option_list <- list(
    make_option(c("-m","--modelfile"),default="mlda.40.rdsv2")
)

opt <- parse_args(OptionParser(option_list=option_list),positional_arguments=1)
mlda <- readRDS(opt$options$modelfile)
loc <- opt$args[1]

getpaper.dtm <- function (url) {
    if (grepl("^http.?:",c(url))[1]) {
        resp <- GET(url)
        if(resp$status_code != 200) { warning(paste("url returned ",resp$status_code)) ; return() }
        lines <- str_split(httr::content(resp, as="text"),"\\n")[[1]]
    } else {
        lines <- str_split(read_file(url),"\\n")[[1]]
    }
    startline = 1
    if (length(str_which(lines,'---'))) startline = last(str_which(lines,'---'));
                                        # find yaml header
    lines <- lines[startline:length(lines)] # drop yaml hdr
    ctxt <- Corpus(VectorSource(str_c( str_replace_all(lines, "\\[@[^]]+\\]",""), collapse="")))
    return( DocumentTermMatrix(ctxt,control=list(stopwords=TRUE,removePunctuation=TRUE,removeNumbers=TRUE,stemming=TRUE, wordLengths=c(4,50))) )
}

## mapping the single-document dtm to the model is a matter of transforming the j-vector to match the model's term coordinates
## dimnames(cdtm)$Terms is the terms vector

## cdtm  - single document DocumentTermMatrix
## mlda - TopicModel (LDA_VEM)

## the output of xfm.dtm will run as newdata in posterior(mlds, newdata=.)
xfm.dtm <- function (cdtm,mlda) {
    xdtm <- as.simple_triplet_matrix(array())
    attr(xdtm,"class") <- c("DocumentTermMatrix","simple_triplet_matrix")
    attr(xdtm,"weighting") <- c("term frequency","tf")
    xdtm$ncol <- length(mlda@terms)
    xdtm$nrow <- as.integer(1)
    cterms <- dimnames(cdtm)$Terms
    mtch <- match(cterms, mlda@terms)
    xdtm$j <- mtch[!is.na(mtch)]
    xdtm$v <- cdtm$v[!is.na(mtch)]
    xdtm$i <- rep(as.integer(1),length(xdtm$j))
    xdtm$dimnames <- c(list("1"), list(mlda@terms)) # entire original terms vector
    names(xdtm$dimnames) <- c("Docs","Terms")
    return(xdtm)
}

## main
pdtm <- getpaper.dtm(loc)
xdtm <- xfm.dtm( pdtm, mlda ) # transformed dtm of paper slurped and preprocessed from github
vec <- posterior(mlda, xdtm)$topics[1,] # is the estimated gamma for the single paper represented in xdtm
write(vec,file=stdout(),ncolumns=1)


