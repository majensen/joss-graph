use v5.10;
use lib 'lib';
use utf8::all;
use Carp qw/carp/;
use Net::GitHub::V4;
use Mojo::URL;
use Try::Tiny;
use Template::Tiny;
use JOSS::GHQueries;
use JSON::ize;
use strict;
use warnings;

my $tt = Template::Tiny->new();
my $papers = J('papers.json');
  
open my $cred, "$ENV{HOME}/.git-credentials" or die $!;
my @cred = <$cred>;
my $ng = Net::GitHub::V4->new(
  access_token => Mojo::URL->new($cred[0])->password,
 );
my $dta;
my %prereviews;

for my $issn (sort { $a <=> $b } keys %$papers) {
  my $prerev;
  try {
    $dta = $ng->query( make_qry('prereview_issue_by_review_issue', { number => $issn } ) );
  } catch {
    say "Query on $issn failed: $_";
    next;
  };
  my $nodes = $dta->{data}{organization}{repository}{issue}{timelineItems}{edges};
  for (@$nodes) {
    my $src = $_->{node}{source};
    if ($src->{author}{login} eq 'whedon' and $src->{title} =~ /^\s*\[PRE\s*REVIEW\]/) {
      @{$prerev}{qw/number url/} = @{$src}{qw/number url/};
      $prereviews{$issn} = $prerev;
      last;
    }
  }
  carp "No pre-review issue found for $issn" unless $prerev;
}

say J(\%prereviews);

sub make_qry {
  my ($qname, $args) = @_;
  my $q;
  $tt->process( \$gh_queries{$qname}, $args, \$q );
  return $q;
}
