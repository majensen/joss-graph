#!/usr/bin/env perl
use Mojolicious::Lite;
use IPC::Run qw/run timeout/;
use Try::Tiny;

sub TIMEOUT() { 180 } # gh query can take a while

my ($in, $out, $err);
my @upd_cmd = ( ['update-ghquery.pl'],'|', ['load-update.pl'], '|', ['cypher-shell'] );

# update
# get logs
# change parameters
app->secrets(['}W4t{K&bwhd!*VJZ','^MbGdwx%="ep8m-7']);
app->log->path('minisrv.log');

get '/' => sub {
  my $c = shift;
  my $ping;
  try {
    $ping=$c->ua->get("127.0.0.1:7474")->result;
  } catch {
    1;
  };
  if (!$ping || $ping->is_error) {
    $c->render( json => { result => 'WAIT' } );
  }
  elsif ($ping->is_success) {
    $c->render( json => { result => 'READY' } );
  }
  else {
    $c->render( json => { result => 'WHAT?' } );
  }
};

get '/update' => sub {
  my $c = shift;
  $out = $err = '';
  run @upd_cmd, \$in,\$out,\$err, timeout(TIMEOUT);
  if ($err) {
    app->log->error($err);
    $c->render( json => { result => "ERROR",
			  message => $err }, status => 500)
  }
  else {
    $c->render(json => { result => "ACK" });
  }
};

get '/ghquery' => sub {
  my $c = shift;
  $out = $err = '';
  run ['update-ghquery.pl'],\$in,\$out,\$err, timeout(TIMEOUT);
  if ($err) {
    app->log->error($err);
    $c->render( json => { result => "ERROR",
			  message => $err }, status => 500 );
  }
  else {
    $c->render( text => $out, format => 'json' );
  }
};

get '/cypher' => sub {
  my $c = shift;
  $out = $err = '';
  run ['update-ghquery.pl'],'|', ['load-update.pl'], \$in, \$out, \$err;
  if ($err) {
    app->log->error($err);
    $c->render( json => { result => "ERROR",
			  message => $err }, status => 500 );
  }
  else {
    $c->render( text => $out );
  }
};

get '/log/:thing' => sub {
  my $c = shift;
  for ($c->stash('thing')) {
    /^neo4j$/ && do {
      $c->reply->file('/var/log/neo4j/debug.log');
      last;
    };
    /^minisrv$/ && do {
      $c->reply->file('/opns/minisrv.log');
      last;
    };
    app->log->error($c->stash('thing')." is not an endpoint for /log");
    $c->render( json => { result => "ERROR",
			  message => "'".$c->stash('thing')."' not an endpoint: valid are 'neo4j' and 'minisrv'"}, status => 400 );
  }
};

app->start;
