package Mojolicious::Command::generate::rest_app;
use Mojo::Base 'Mojo::Command';

# ABSTRACT: Generate a Psuedo-RESTful Mojolicious/DBIx::Class Application
# VERSION

use strict;
use warnings;
use 5.008001;
use DBIx::Class::Schema::Loader qw/ make_schema_at /;

=head1 SYNOPSIS

    mojo generate rest_app MyApp dbi:SQLite:./app.db
    ...

=head1 DESCRIPTION

Mojo::Command::generate::rest_app is a Mojolicious application generator
that uses L<DBIx::Class> to generate CRUD scaffolding. 

    use Mojo::Command::generate::rest_app;
 
    my $app = Mojo::Command::generate::rest_app->new;
    $app->run(@ARGV);

=cut

has description => <<'EOF';
Generate a RESTful Mojolicious application directory structure.
EOF

has usage => <<"EOF";
usage: $0 generate rest_app [CLASS] [DSN] [USER] [PASS]
EOF

sub run {
    my ( $self, $class, $dsn, $user, $pass ) = @_;
    
    # Requied information
    die <<EOF unless $class && $dsn;
Please issue a valid application class and database connection string.
EOF

    # Prevent bad application naming, sri's policy not mine
    die <<EOF unless $class =~ /^[A-Z](?:\w|\:\:)+$/;
Your application name has to be a well formed (camel case) Perl module name
like "MyApp".
EOF

    my @connection_string = ($dsn);
    
    push @connection_string, $user if $user;
    push @connection_string, $pass if $pass;
    
    my $name = $self->class_to_file($class);
    my $model = join('::', $class, 'Model');
    
    $self->create_rel_dir("$name/lib");
    
    # Model
    make_schema_at(
        $model,
        {
            debug          => 0,
            dump_directory => "$name/lib",
        },
        [
            @connection_string
        ],
    );
    
    # Build Controllers
    my $database = $model->connect(@connection_string);
    my $schema = { map { $_ => $database->source($_)->{_columns} } $database->sources };
    if ($schema) {
        foreach my $source ( sort keys %$schema ) {

            # Controller
            my $controller = "${class}::Controller::$source";
            my $path       = $self->class_to_path($controller);
            $self->render_to_rel_file(
                'controller', "$name/lib/$path",
                $controller, $source, $schema->{$source},
                [$database->source($source)->primary_columns]
            );
        }
    }
    
    # Main Controller
    my $controller = "${class}::Controller";
    my $path       = $self->class_to_path($controller);
    $self->render_to_rel_file( 'hubble', "$name/lib/$path",
        $controller,
        [map { $self->class_to_file($_) } keys %{$schema}]
    );
    
    # Script
    $self->render_to_rel_file( 'mojo', "$name/script/$name", $class );
    $self->chmod_file( "$name/script/$name", 0744 );
    
    # Application
    my $app = $self->class_to_path($class);
    $self->render_to_rel_file( 'appclass', "$name/lib/$app",
        $class, $model,
        {
            map {
                $self->class_to_file($_) => {
                    class   => $_,
                    columns => [sort keys %{$schema->{$_}}]
                  }
              } keys %{$schema}
        },
        @connection_string
    );
    
    # Basic Test
    $self->render_to_rel_file( 'test', "$name/t/basic.t", $class );
    
    # Model Tests
    if ($schema) {
        foreach my $source ( sort keys %$schema ) {

            # Controller
            my $path = $self->class_to_file($source);
            $self->render_to_rel_file(
                'modeltest', "$name/t/$path.t",
                $class, $path, $source, $schema->{$source},
                [$database->source($source)->primary_columns]
            );
        }
    }
    
    # Log
    $self->create_rel_dir("$name/log");
    
    # Static
    $self->render_to_rel_file( 'static', "$name/public/index.html" );
}

1;    # End of Mojo::Command::generate::rest_app

__DATA__

@@ mojo
% my $class = shift;
#!/usr/bin/env perl
use Mojo::Base -strict;

use File::Basename 'dirname';
use File::Spec;

use lib join '/', File::Spec->splitdir(dirname(__FILE__)), 'lib';
use lib join '/', File::Spec->splitdir(dirname(__FILE__)), '..', 'lib';

# Check if Mojo is installed
eval 'use Mojolicious::Commands';
die <<EOF if $@;
It looks like you don't have the Mojolicious Framework installed.
Please visit http://mojolicio.us for detailed installation instructions.

EOF

# Application
$ENV{MOJO_APP} ||= '<%= $class %>';

# Start commands
Mojolicious::Commands->start;

@@ appclass
% my $class = shift;
% my $model = shift;
% my $routes = shift;
% my $dsn = shift;
% my $user = shift;
% my $pass = shift;
package <%= $class %>;
use Mojo::Base 'Mojolicious';
use <%= $model %>;

# This method will run once at server start
sub startup {
  my $self = shift;

  # View Access
  $self->helper( view => sub {
    my ($self, $status, $message, $data) = @_;
    $self->render_json({
        status => $status ? Mojo::JSON->true : Mojo::JSON->false,
        message => $message,
        data => $data || []
    });
  });
  $self->helper( success => sub {
    my ($self, $message, $data) = @_;
    $self->view(1, $message || "Operation succeeded", $data || []);
  });
  $self->helper( failure => sub {
    my ($self, $message, $data) = @_;
    $self->view(0, $message || "Operation failed", $data || []);
  });
  
  # Model Access
  $self->helper( model => sub {
    my $model = <%= $model %>->connect('<%= $dsn %>'<% if ($user) { %>, '<%= $user %>'<% } %><% if ($pass) { %>, '<%= $pass %>'<% } %>);
    return $_[1] ? $model->resultset($_[1]) : $model ;
  });

  # Controller Access
  my $r = $self->routes;
  $r->add_shortcut(controller => sub {
    my ($r, $class) = @_;
    my @n = ('namespace', 'Api::Controller');
    my $p = Mojolicious::Commands->class_to_file($class);
    my $from = $r->bridge("/$p")->to( @n, action => $p );
    push @n, 'controller', $class;
       $from->route('/new')->to(@n, action => "create");
       $from->route('/list')->to(@n, action => "read");
       $from->route('/edit')->to(@n, action => "update");
       $from->route('/delete')->to(@n, action => "delete");
    return $from;
  });
  <% foreach my $route (sort keys %{$routes}) { %>
  $r->controller('<%= $routes->{$route}->{class} %>');
  <% } %>
  $r->route('/')->to('controller#index');
  
}

1;

@@ hubble
% my $class = shift;
% my $bridges = shift;
package <%= $class %>;
use Mojo::Base 'Mojolicious::Controller';

sub index {
  my $self = shift;

  # Render template "index.html.ep" with welcome message
  $self->success('Welcome to the Mojolicious REST server!');
}
<% foreach my $bridge (sort @{$bridges}) { %>
sub <%= $bridge %> {
  my $self = shift;

  # bridge
  return 1;
}    
<% } %>

1;

@@ controller
% my $class = shift;
% my $source = shift;
% my $columns = shift;
% my $keys = shift;
% my @required = ();
% for (sort keys %{$columns}){ push @required, "\$$_" unless $columns->{$_}->{is_nullable} && ! $columns->{$_}->{is_auto_increment} }
package <%= $class %>;
use Mojo::Base 'Mojolicious::Controller';

# This action will create a new object in the database
sub create {
  my $self = shift;
  
  # define input parameters
  <% foreach my $col (sort keys %{$columns}) { %>
  my $<%= $col %> = $self->param('<%= $col %>') <% if ($columns->{$col}->{is_nullable} || $columns->{$col}->{is_auto_increment}) { %>|| undef<% } %>;
  <% } =%><%%>
  
  # check required input parameters
  $self->failure("operation failed, required input missing") unless
    <%= join " && ", @required %>;
  
  # create database object
  
  my $model = $self->model('<%= $source %>')->new({});
  
  # set columns
  <% foreach my $col (sort keys %{$columns}) { %>
  $model-><%= $col %>($<%= $col %>)<% unless ($columns->{$col}->{is_nullable} || $columns->{$col}->{is_auto_increment}) { %> if $<%= $col %><% } %>;
  <% } =%><%%>
  
  $model->insert ?
    $self->success("operation was successful", [{ $model->get_columns }]) :
    $self->failure("operation failed") ;
    
}

# This action will list existing objects in the database
sub read {
  my $self = shift;
  
  # define search parameters
  my $search = {};
  my @input = qw/<% foreach my $col (sort keys %{$columns}) { %>
    <%= $col %>
  <% } =%><%%>
  /;
  
  foreach (@input) {
    $search->{$_} = $self->param($_) if $self->param($_);
  }

  # fetch database object
  
  my $model = $self->model('<%= $source %>')->search( $search, {
        page => 1, rows => 1000,
        result_class => 'DBIx::Class::ResultClass::HashRefInflator'
    }
  );
  
  my $data = [$model->all];
  
  @{$data} ?
    $self->success("search was successful", $data) :
    $self->failure("search was unsuccessful", $data) ;

}

# This action will update an existing object in the database
sub update {
  my $self = shift;
  
  # define input parameters
  <% foreach my $col (sort keys %{$columns}) { %>
  my $<%= $col %> = $self->param('<%= $col %>') <% if ($columns->{$col}->{is_nullable} || $columns->{$col}->{is_auto_increment}) { %>|| undef<% } %>;
  <% } =%><%%>

  # fetch database object
  
  return $self->failure("operation failed, required information missing")
    unless <%= join " && ", map { "\$$_" } @{$keys} %>;
  
  my $model = $self->model('<%= $source %>')->single({
    <% foreach my $key (@{$keys}) { %><%= $key %> => $<%= $key %>,
    <% } =%><%%>
  });
  
  return $self->failure("operation failed, no record found")
    unless $model;
  
  # set columns
  <% foreach my $col (sort keys %{$columns}) { %>
  $model-><%= $col %>($<%= $col %>)<% unless ($columns->{$col}->{is_nullable} || $columns->{$col}->{is_auto_increment}) { %> if $<%= $col %><% } %>;
  <% } =%><%%>
  
  $model->update ?
    $self->success("operation was successful", [{ $model->get_columns }]) :
    $self->failure("operation failed") ;

}

# This action will delete an existing object in the database
sub delete {
  my $self = shift;
  
  # define input parameters
  <% foreach my $col (sort @{$keys}) { %>
  my $<%= $col %> = $self->param('<%= $col %>');
  <% } =%><%%>

  # fetch database object
  
  return $self->failure("operation failed, required information missing")
    unless <%= join " && ", map { "\$$_" } @{$keys} %>;
  
  my $model = $self->model('<%= $source %>')->single({
    <% foreach my $key (@{$keys}) { %><%= $key %> => $<%= $key %>,
    <% } =%><%%>
  });
  
  return $self->failure("operation failed, no record found")
    unless $model;
  
  $model->delete ?
    $self->success("operation was successful", [{ $model->get_columns }]) :
    $self->failure("operation failed") ;

}

1;

@@ static
<!doctype html><html>
  <head><title>Welcome to the Mojolicious REST server!</title></head>
  <body>
    <h2>Welcome to the Mojolicious REST server!</h2>
    I am the Mojolicious REST API. I am okay with you
    manipulating me but I will not stand for abuse.
  </body>
</html>

@@ test
% my $class = shift;
#!/usr/bin/env perl
use Mojo::Base -strict;

use Test::More tests => 4;
use Test::Mojo;

use_ok '<%= $class %>';

my $t = Test::Mojo->new('<%= $class %>');
$t->get_ok('/')->status_is(200)->json_content_is(
    {
        status  => Mojo::JSON->true,
        message => "Welcome to the Mojolicious REST server!"
    }
);

@@ modeltest
% my $class = shift;
% my $route = shift;
% my $source = shift;
% my $columns = shift;
% my $keys = shift;
#!/usr/bin/env perl
use Mojo::Base -strict;

use Test::More tests => 13;
use Test::Mojo;

use_ok '<%= $class %>';

my $t = Test::Mojo->new('<%= $class %>');
$t->get_ok('/<%= $route %>/new')->status_is(200)->json_content_is(
    {
        status  => Mojo::JSON->false,
        message => "operation failed, required input missing",
        data => []
    }
);
$t->get_ok('/<%= $route %>/edit')->status_is(200)->json_content_is(
    {
        status  => Mojo::JSON->false,
        message => "operation failed, required information missing",
        data => []
    }
);
$t->get_ok('/<%= $route %>/delete')->status_is(200)->json_content_is(
    {
        status  => Mojo::JSON->false,
        message => "operation failed, required information missing",
        data => []
    }
);
$t->get_ok('/<%= $route %>/list')->status_is(200)->json_content_is(
    {
        status  => Mojo::JSON->false,
        message => "search was unsuccessful",
        data => []
    }
);
