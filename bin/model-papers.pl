use v5.10;
use lib "../lib";
use IPC::Run qw/run/;
use JSON::ize;

my $d;
my $re = qr/joss\.([0-9]+)\.jats\.md/;
my $paperdir = "papers.2/";
opendir $d, $paperdir;
my @files = readdir $d;
my @papers = grep $re, @files;
my $i = 0;
for $p (@papers) {
  my ($in, $out, $err);
  print STDERR "$i\n" unless ++$i % 25;
  my $f = $paperdir.$p;
  my ($issue) = $f =~ $re;
  next unless $issue;
  if (!run [split / /,"./topicize.r $f"], \$in, \$out,\$err) {
    print STDERR "error in topicize.r:\n$err";
    print STDERR "fail paper $issue\n";
  }
  else {
    my @ret = split /\n/,$out;
    say join("\t", $issue, @ret);
  }
}
1;



  
