#!/usr/bin/env perl
use Mojolicious::Lite;

use DBI;

#======================#
# Customizations
#======================#
my $config = {
	routes => app->home->rel_file('../routes')->realpath,
	database => app->home->rel_file('../database')->realpath
};

app->renderer->paths([$config->{routes}]);
app->renderer->cache->max_keys(0);

#======================#
# Initiations
#======================#
my $dbh = DBI->connect ("dbi:CSV:", undef, undef, {
    f_ext      => ".csv/r",
	f_dir	   => $config->{database},
    RaiseError => 1,
    }) or die "Cannot connect: $DBI::errstr";
	

get '/' => sub {
  my ($c, @data) = (shift);
  my $sth = $dbh->prepare ("select * from test");
  $sth->execute;
  while (my $row = $sth->fetchrow_hashref) { push(@data, $row) }
  $sth->finish ();
  
  $c->stash(pagedata => [@data]);
	  
  $c->render(template => 'index');
};

get '/:table/:action' => sub {
	my $c = shift;
};

# Not found (404)
get '/missing' => sub {
	my $c = shift;
  	$c->render(template => 'does_not_exist');
};

# Exception (500)
get '/dies' => sub { die 'Intentional error' };


app->start;