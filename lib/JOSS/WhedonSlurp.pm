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
  my ($body) = (@_);
  my $ret;
  $log->logcarp("parse_issue_body: arg doesn't look like a whedon-created issue description")
    unless ($body =~ /Submitting author/);
  for (split /\n/,$body) {
    /Submitting author/ && do {
      /\@(\S+)/;
      $1 && ($ret->{author}{handle} = $1);
      /href="([^"]+)"/;
      $1 && ($ret->{author}{orcid} = $1);
      m|>(.*)</a>|;
      $1 && ($ret->{author}{name} = $1);
      next;
    };
    /Repository/ && do {
      /href="([^"]+)"/;
      $1 && ($ret->{repo} = $1);
      next;
    };
    /Version/ && do {
      next if $ret->{version};
      /\*\*Version:\*\*\s+(\S+)/;
      $1 && ($ret->{version} = $1);
      next;
    };
    /Editor/ && do {
      /\@(\S+)/;
      $1 && ($ret->{editor} = $1);
      next;
    };
    /Reviewer/ && do {
      my @rev = /\@(\S+)/g;
      @rev && push(@{$ret->{reviewers}}, @rev);
      next;
    };
    /reviewer questions/i && last;
  }
  $ret;  
}

1;
  
