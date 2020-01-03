# reads the crossref.xml for every paper in local clone of openjournals/joss-papers 
# and outputs json
use v5.10;
use utf8::all;
use lib 'lib';
use Try::Tiny;
use File::Find;
use XML::Twig;
use JSON::ize;
use strict;
use warnings;


my $paper_repo = "./joss-papers";
my %papers;
my @errored;
pretty_json;

find(
  sub {
    1;
    return unless /^.*joss\.([0-9]+)\.crossref\.xml/;
    my ($id) = 0+$1;
    my $info = $papers{$id} = {};
    $$info{id} = $id;
    my $t = XML::Twig->new(pretty_print => 'indented');
    $t->parsefile($_);
    my $r = $t->root;
    $$info{authors} = get_authors($r);
    $$info{published_date} = get_pubdate($r);
    $$info{title} = get_title($r);
    $$info{review_issue} = get_review_issue($r);
    @{$info}{qw/volume issue/} = get_issue($r);
    @{$info}{qw/joss_doi archive_doi url/} = get_dois($r);
    1;
  }, $paper_repo);

print J(\%papers);


sub get_authors {
  my ($r) = @_;
  my @persons;
  for my $au ($r->first_descendant('contributors')->children) {
    my $p;
    next unless $au->has_children;
    try {
      $p->{first_name} = $au->first_child('given_name')->text;
      $p->{last_name} = $au->first_child('surname')->text;
      if (my $ch = $au->first_child('orcid') // $au->first_child('ORCID')) {
	$p->{orcid} = $ch->text;
      }
    } catch {
      no warnings;
      no strict;
      say STDERR "Error at $File::Find::name";
      say STDERR $_;
      $DB::single=1;
      $au->print(STDERR, 'indented')
    };
    push @persons, $p;
  }
  return \@persons;
}

sub get_pubdate {
  my ($r) = @_;
  my $mo = $r->first_descendant('publication_date')->first_child('month')->text;
  my $yr = $r->first_descendant('publication_date')->first_child('year')->text;
  return "$yr-$mo";
}

sub get_title {
  my ($r) = @_;
  my $title = $r->first_descendant('journal_article')->first_child('titles')->first_child->text;
  return $title;
}

sub get_issue {
  my ($r) = @_;
  my $vol = $r->first_descendant('journal_issue')->first_descendant('volume')->text;
  my $iss = $r->first_descendant('journal_issue')->first_descendant('issue')->text;
  return ($vol, $iss);
}

sub get_review_issue {
  my ($r) = @_;
  my $riss;
  for my $ri ($r->first_descendant('rel:program')->children('rel:related_item')) {
    if ($ri->first_child('rel:description')->text =~ /review issue/) {
      $riss = $ri->first_child('rel:inter_work_relation[@relationship-type="hasReview"]')->text;
    }
  }
  return $riss;
}
sub get_dois {
  my ($r) = @_;
  my $adoi;
  my $jdoi = $r->first_descendant('publisher_item')->first_child('identifier[@id_type="doi"]')->text;
  for my $ri ($r->first_descendant('rel:program')->children('rel:related_item')) {
    if ($ri->first_child('rel:description')->text =~ /archive/) {
      $adoi = $ri->first_child('rel:inter_work_relation[@identifier-type="doi"]')->text;
      $adoi =~ s/^.*doi\.org\///;
    }
  }
  my $url = $r->first_descendant('journal_article')->first_descendant('doi_data')->first_child('resource')->text;
  return ($jdoi, $adoi, $url);
}

    
