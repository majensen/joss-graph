package JOSS::WhedonSlurp;
use v5.10;
use Log::Log4perl::Tiny qw/:easy/;
use strict;
use warnings;

# Object to extract info from various Whedon-created responses
my $log = get_logger();

sub new {
  my ($class) = @_;
  my $self = {};
  bless $self, $class;
}

sub parse_issue_body {
  my $self = shift;
  my ($iss) = (@_);
  my $ret;
  my $body = $iss->{body};
  my $num = $iss->{number};
  if ($body =~ /STOP STOP/) {
    $log->logcarp("parse_issue_body: Issue $num - somebody made a boo boo.");
    return;
  }
  if ($body !~ /Submitting author/) {
    $log->logcarp("parse_issue_body: Issue $num - arg doesn't look like a whedon-created issue description");
    return;
  }
  for (split /\n/,$body) {
    /Submitting author/ && do {
      /\@(\w+)/;
      $1 && ($ret->{author}{handle} = $1);
      /href="([^"]+)"/;
      $1 && ($ret->{author}{orcid} = $1);
      m|<a[^>]+>(.*)</a>|;
      $1 && ($ret->{author}{name} = $1);
      next;
    };
    /Repository/ && do {
      /repository-->([^<]+)<!--/;
      $1 && ($ret->{repo} = $1);
      next if $ret->{repo};
      /href="([^"]+)"/;
      $1 && ($ret->{repo} = $1);
      next;
    };
    /Version/ && do {
      s/<!--(?:end-)?version-->//g;
      /\*\*Version:\*\*\s+(\S+)/;
      $1 && ($ret->{version} = $1);
      next;
    };
    /Editor/ && do {
      /\@(\w+)/;
      $1 && ($ret->{editor} = $1);
      next;
    };
    /Reviewer/ && do {
      my @rev;
      s/<!--(?:end-)?reviewers-list-->//g;
      /\*\*Reviewers:\*\*\s*(.*)/;
      $1 && do {
	$_ = $1;
	s/\s*$//;
	y/@//d;
	@rev = split(/,\s*/)
      };
      @rev && push(@{$ret->{reviewers}}, @rev);
      next;
    };
    /Branch/ && do {
      /branch-->([^<]+)<!--/;
      $1 && ($ret->{branch} = $1);
      next;
    };
    /Archive/ && do {
      /archive-->([^<]+)<!--/;
      $1 && ($ret->{archive} = $1);
      next;
    };
    /reviewer questions|status/i && last;
  }
  $ret;  
}

1;
  
