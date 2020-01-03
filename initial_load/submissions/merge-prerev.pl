# merge prereview data with submissions
# create cypher statements
use v5.10;
use Carp qw/carp croak/;
use JSON::ize;
use Neo4j::Cypher::Abstract qw/cypher ptn/;
use strict;
use warnings;

my $prerevs = J('prerev.json');
my @cypher;

for my $issn (sort {$a <=> $b} keys %$prerevs) {
  my $pr = $prerevs->{$issn};

  push @cypher, cypher->match( ptn->N('s:submission') )
    ->where( { 's.joss_doi' => { '=~' => ".*joss.0*$issn" } } )
    ->set( { 's.prerev_issue' => $pr->{url} }).';';

  1;
}

say $_ for @cypher;

1;
