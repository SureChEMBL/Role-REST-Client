package Role::REST::Client;

use Moose::Role;
use Moose::Util::TypeConstraints;
use URI::Escape::XS 'uri_escape';
use Try::Tiny;

use Carp qw(confess);
use Role::REST::Client::Serializer;
use Role::REST::Client::Response;
use HTTP::Response;
use HTTP::Status 'status_message';
use HTTP::Headers;

with 'MooseX::Traits';

has 'server' => (
	isa => 'Str',
	is  => 'rw',
);
has 'type' => (
	isa => enum ([qw{application/json application/xml application/yaml application/x-www-form-urlencoded}]),
	is  => 'rw',
	default => 'application/json',
);
has clientattrs => (isa => 'HashRef', is => 'ro', default => sub {return {} });

has user_agent => (
	isa => duck_type([qw(request)]),
	is => 'ro',
	lazy => 1,
	builder => '_build_user_agent',
);

sub _build_user_agent {
	my $self = shift;
	require HTTP::Thin;
	return HTTP::Thin->new(%{$self->clientattrs});
}

has persistent_headers => (
	traits    => ['Hash'],
	is        => 'ro',
	isa       => 'HashRef[Str]',
	default   => sub { {} },
        lazy      => 1,
	trigger	  => sub {
		my ( $self, $header, $old_header ) = @_;
		# Update httpheaders if their value was initialized first
		while (my ($key, $value) = each %$header) {
			$self->set_header($key, $value) unless $self->exist_header($key);
		}
	},
	handles   => {
		set_persistent_header     => 'set',
		get_persistent_header     => 'get',
		has_no_persistent_headers => 'is_empty',
		clear_persistent_headers  => 'clear',
	},
);
has httpheaders => (
	traits      => ['Hash'],
	is          => 'ro',
	isa         => 'HashRef[Str]',
        lazy        => 1,
	writer      => '_set_httpheaders',
	builder     => '_build_httpheaders',
	initializer => '_build_httpheaders',
	handles     => {
		set_header     => 'set',
		get_header     => 'get',
		exist_header   => 'exists',
		has_no_headers => 'is_empty',
		clear_headers  => 'clear',
	},
);

has serializer_class => (
	isa => 'ClassName', is => 'ro',
	default => 'Role::REST::Client::Serializer',
);

no Moose::Util::TypeConstraints;

sub _build_httpheaders {
	my ($self, $headers) = @_;
	$headers ||= {};
	$self->_set_httpheaders( { %{$self->persistent_headers}, %$headers });
}

sub reset_headers {my $self = shift;$self->_set_httpheaders({ %{$self->persistent_headers} })}

sub _rest_response_class { 'Role::REST::Client::Response' }

# If the response is a hashref, we expect it to be in the format returned by
# HTTP::Tiny->request() and convert it to an HTTP::Response object.  Otherwise,
# pass the response through unmodified.
sub _handle_response {
	my ( $self, $res ) = @_;
	if ( ref $res eq 'HASH' ) {
		my $code = $res->{'status'};
		return HTTP::Response->new(
			$code,
			$res->{'reason'} || status_message($code),
			HTTP::Headers->new(%{$res->{'headers'}}),
			$res->{'content'},
		);
	} else {
		return $res;
	}
}

sub _new_rest_response {
	my ($self, @args) = @_;
	return $self->_rest_response_class->new(@args);
}

sub new_serializer {
	my ($self, @args) = @_;
	$self->serializer_class->new(@args);
}

sub _serializer {
	my ($self, $type) = @_;
	$type ||= $self->type;
	$type =~ s/;\s*?charset=.+$//i; #remove stuff like ;charset=utf8
	try {
		$self->{serializer}{$type} ||= $self->new_serializer(type => $type);
	}
	catch {
		# Deal with real life content types like "text/xml;charset=ISO-8859-1"
		warn "No serializer available for " . $type . " content. Trying default " . $self->type;
		$self->{serializer}{$type} = $self->new_serializer(type => $self->type);
	};
	return $self->{serializer}{$type};
}

sub do_request {
	my ($self, $method, $uri, $opts) = @_;
	return $self->user_agent->request($method, $uri, $opts);
}

sub _call {
	my ($self, $method, $endpoint, $data, $args) = @_;
	my $uri = $self->server.$endpoint;
	# If no data, just call endpoint (or uri if GET w/parameters)
	# If data is a scalar, call endpoint with data as content (POST w/parameters)
	# Otherwise, encode data
	$self->set_header('content-type', $self->type);
	my %options = (headers => $self->httpheaders);
	if ( defined $data ) {
		$options{content} = ref $data ? $self->_serializer->serialize($data) : $data;
		$options{'headers'}{'content-length'} = length($options{'content'});
	}
	my $res = $self->_handle_response( $self->do_request($method, $uri, \%options) );
	$self->reset_headers unless $args->{preserve_headers};
	# Return here if there was an error
	return $self->_new_rest_response(
		code => $res->code,
		response => $res,
		error => $res->message,
        ) if $res->is_error;

	my $deserializer_cb = sub {
		# Try to find a serializer for the result content
		my $content_type = $args->{deserializer} || $res->header('Content-Type');
		my $deserializer = $self->_serializer($content_type);
		# Try to deserialize
		my $content = $res->decoded_content;
		$content = $deserializer->deserialize($content) if $deserializer && $content;
		$content ||= {};
	};
	return $self->_new_rest_response(
		code => $res->code,
		response => $res,
		data => $deserializer_cb,
        );
}

sub _urlencode_data {
	my ($self, $data) = @_;
	return join '&', map { uri_escape($_) . '=' . uri_escape($data->{$_})} keys %$data;
}

sub _request_with_query {
	my ($self, $method, $endpoint, $data, $args) = @_;
	my $uri = $endpoint;
	if ($data && scalar keys %$data) {
		$uri .= '?' . $self->_urlencode_data($data);
	}
	return $self->_call($method, $uri, undef, $args);
}

sub get { return shift->_request_with_query('GET', @_) }

sub head { return shift->_request_with_query('HEAD', @_) }

sub delete { return shift->_request_with_query('DELETE', @_) }

sub _request_with_body {
	my ($self, $method, $endpoint, $data, $args) = @_;
	my $content = $data;
	if ( $self->type =~ /urlencoded/ ) {
		$content = ( $data && scalar keys %$data ) ? $self->_urlencode_data($data) : q{};
	}
	return $self->_call($method, $endpoint, $content, $args);
}

sub post { return shift->_request_with_body('POST', @_) }

sub put { return shift->_request_with_body('PUT', @_) }

sub options { return shift->_request_with_body('OPTIONS', @_) }

1;

__END__

# ABSTRACT: REST Client Role

=pod

=head1 NAME

Role::REST::Client - REST Client Role

=head1 SYNOPSIS

	{
		package RESTExample;

		use Moose;
		with 'Role::REST::Client';

		sub bar {
			my ($self) = @_;
			my $res = $self->post('foo/bar/baz', {foo => 'bar'});
			my $code = $res->code;
			my $data = $res->data;
			return $data if $code == 200;
	   }

	}

	my $foo = RESTExample->new(
		server =>      'http://localhost:3000',
		type   =>      'application/json',
		clientattrs => {timeout => 5},
	);

	$foo->bar;

	# controller
	sub foo : Local {
		my ($self, $c) = @_;
		my $res = $c->model('MyData')->post('foo/bar/baz', {foo => 'bar'});
		my $code = $res->code;
		my $data = $res->data;
		...
	}

=head1 DESCRIPTION

This REST Client role makes REST connectivety easy.

Role::REST::Client will handle encoding and decoding when using the four HTTP verbs.

	GET
	PUT
	POST
	DELETE
	OPTIONS
	HEAD

Currently Role::REST::Client supports these encodings

	application/json
	application/x-www-form-urlencoded
	application/xml
	application/yaml

x-www-form-urlencoded only works for GET and POST, and only for encoding, not decoding.

=head1 METHODS

=head2 methods

Role::REST::Client implements the standard HTTP 1.1 verbs as methods

	post
	get
	head
	put
	delete
	options

All methods take these parameters

	url - The REST service
	data - The data structure (hashref, arrayref) to send. The data will be encoded
		according to the value of the I<type> attribute.
	args - hashref with arguments to augment the way the call is handled.

args - the optional argument parameter can have these entries

	deserializer - if you KNOW that the content-type of the response is incorrect,
	you can supply the correct content type, like
	my $res = $self->post('foo/bar/baz', {foo => 'bar'}, {deserializer => 'application/yaml'});

	preserve_headers - set this to true if you want to keep the headers between calls

All methods return a response object dictated by _rest_response_class. Set to L<Role::REST::Client::Response> by default.

=head1 ATTRIBUTES

=head2 user_agent

  sub _build_user_agent { HTTP::Thin->new }

A User Agent object which has a C<< ->request >> method suitably compatible with L<HTTP::Tiny>. It should accept arguments like this: C<< $ua->request($method, $uri, $opts) >>, and needs to return a hashref as HTTP::Tiny does, or an L<HTTP::Response> object.  To set your own default, use a C<_build_user_agent> method.

=head2 server

URL of the REST server.

e.g. 'http://localhost:3000'

=head2 type

MIME Content-Type header,

e.g. application/json

=head2 httpheaders

  $self->set_header('Header' => 'foo', ... );
  $self->get_header('Header-Name');
  $self->has_no_headers;
  $self->clear_headers;

You can set any http header you like with set_header, e.g.
$self->set_header($key, $value) but the content-type header will be overridden.

=head2 persistent_headers

  $self->set_persistent_header('Header' => 'foo', ... );
  $self->get_persistent_header('Header-Name');
  $self->has_no_persistent_headers;
  $self->clear_persistent_headers;

A hashref containing headers you want to use for all requests. Use the methods
described above to manipulate it.

To set your own defaults, override the default or call C<set_persistent_header()> in your
C<BUILD> method.

  has '+persistent_headers' => (
    default => sub { ... },
  );

=head2 clientattrs

Attributes to feed the user agent object (which defaults to L<HTTP::Thin>)

e.g. {timeout => 10}

=head1 AUTHOR

Kaare Rasmussen, <kaare at cpan dot com>

=head1 BUGS

Please report any bugs or feature requests to bug-role-rest-client at rt.cpan.org, or through the
web interface at http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Role-REST-Client.

=head1 COPYRIGHT & LICENSE

Copyright 2012 Kaare Rasmussen, all rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as 
Perl itself, either Perl version 5.8.8 or, at your option, any later version of Perl 5 you may 
have available.
