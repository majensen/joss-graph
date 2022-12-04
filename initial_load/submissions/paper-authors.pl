# read json output from papers.pl and get Github ids for the authors
# output person objs in json
use v5.10;
use lib 'lib';
use utf8::all;
use Net::GitHub::V4;
use Mojo::URL;
use Try::Tiny;
use Template::Tiny;
use JOSS::GHQueries;
use JOSS::WhedonSlurp;
use JSON::ize;
use strict;
use warnings;

my $tt = Template::Tiny->new();
my $wdn = JOSS::WhedonSlurp->new();

open my $cred, "$ENV{HOME}/.git-credentials" or die $!;
my @cred = <$cred>;
my $ng = Net::GitHub::V4->new(
  access_token => Mojo::URL->new($cred[0])->password,
 );
my $dta;

pretty_json;
my $papers = J('papers-20200718.json');

my %submissions;

for my $issn (sort { $a <=> $b } keys %$papers) {
  $DB::single =1;
  try {
    $dta = $ng->query( make_qry('issue_body_by_number', { number => $issn } ) );
    die $dta->{message} if $dta->{message};
  } catch {
    say "Query on $issn failed: $_";
    next;
  };
  $submissions{$issn} = $wdn->parse_issue_body($dta->{data}{organization}{repository}{issue}{body});
}

print J(\%submissions);

sub make_qry {
  my ($qname, $args) = @_;
  my $q;
  $tt->process( \$gh_queries{$qname}, $args, \$q );
  return $q;
}

