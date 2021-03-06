package APISchema::Validator;
use strict;
use warnings;
use 5.014;

# cpan
use Class::Load qw(load_class);
use Class::Accessor::Lite::Lazy (
    ro => [qw(fetch_resource_method)],
    ro_lazy => [qw(validator_class)],
);

# lib
use APISchema::Resource;

use constant +{
    DEFAULT_VALIDATOR_CLASS => 'Valiemon',
    TARGETS => [qw(header parameter body)],
    DEFAULT_ENCODING_SPEC => {
        'application/json'                  => 'json',
        'application/x-www-form-urlencoded' => 'url_parameter',
        # TODO yaml, xml
    },
};

sub _build_validator_class {
    return DEFAULT_VALIDATOR_CLASS;
}

sub _new {
    my $class = shift;
    return bless { @_ == 1 && ref($_[0]) eq 'HASH' ? %{$_[0]} : @_ }, $class;
}

sub for_request {
    my $class = shift;
    return $class->_new(@_, fetch_resource_method => 'canonical_request_resource');
}

sub for_response {
    my $class = shift;
    return $class->_new(@_, fetch_resource_method => 'canonical_response_resource');
}

sub _valid_result { APISchema::Validator::Result->new_valid(@_) }
sub _error_result { APISchema::Validator::Result->new_error(@_) }

sub _resolve_encoding {
    my ($content_type, $encoding_spec) = @_;
    # TODO handle charset?
    $content_type = $content_type =~ s/\s*;.*$//r;
    $encoding_spec //= DEFAULT_ENCODING_SPEC;

    if (ref $encoding_spec) {
        $encoding_spec = $encoding_spec->{$content_type};
        return ( undef, { message => "Wrong content-type: $content_type" } )
            unless $encoding_spec;
    }

    my $method = $encoding_spec;
    return ( undef, {
        message      => "Unknown decoding method: $method",
        content_type => $content_type,
    } )
        unless APISchema::Validator::Decoder->new->can($method);

    return ($method, undef);
}

sub _validate {
    my ($validator_class, $decode, $target, $spec) = @_;

    my $obj = eval { APISchema::Validator::Decoder->new->$decode($target) };
    return { message => "Failed to parse $decode" } if $@;

    my $validator = $validator_class->new($spec->definition);
    my ($valid, $err) = $validator->validate($obj);

    return {
        attribute => $err->attribute,
        position  => $err->position,
        message   => "Contents do not match resource '@{[$spec->title]}'",
    } unless $valid;

    return; # avoid returning the last conditional value
}

sub validate {
    my ($self, $route_name, $target, $schema) = @_;

    my @target_keys = grep {
        $target->{$_};
    } @{+TARGETS};
    my $valid = _valid_result(@target_keys);

    return $valid unless scalar @target_keys;

    my $route = $schema->get_route_by_name($route_name)
        or return $valid;
    my $method = $self->fetch_resource_method;
    my $resource_root = $schema->get_resource_root;
    my $resource_spec = $route->$method(
        $resource_root,
        $target->{status_code} ? [ $target->{status_code} ] : [],
        [ @target_keys ],
    );
    @target_keys = grep { $resource_spec->{$_} } @target_keys;

    my $body_encoding = $target->{body} && do {
        my ($enc, $err) = _resolve_encoding(
            $target->{content_type} // '',
            $resource_spec->{encoding},
        );
        if ($err && $resource_spec->{body}) {
            return _error_result(body => $err);
        }
        $enc;
    };

    my $encoding = {
        body      => $body_encoding,
        parameter => 'url_parameter',
        header    => 'perl',
    };

    my $validator_class = $self->validator_class;
    load_class $validator_class;
    my $result = APISchema::Validator::Result->new;
    $result->merge($_) for map {
        my $field = $_;
        my $err = _validate($validator_class, map { $_->{$field} } (
            $encoding, $target, $resource_spec,
        ));
        $err ? _error_result($field => {
            %$err,
            encoding => $encoding->{$_},
        }) : _valid_result($field);
    } @target_keys;

    return $result;
}

package APISchema::Validator::Result;

# core
use List::MoreUtils qw(all);

# cpan
use Hash::Merge::Simple ();
use Class::Accessor::Lite (
    new => 1,
);

sub new_valid {
    my ($class, @targets) = @_;
    return $class->new(values => { map { ($_ => [1]) } @targets });
}

sub new_error {
    my ($class, $target, $err) = @_;
    return $class->new(values => { ( $target // '' ) => [ undef, $err] });
}

sub _values { shift->{values} // {} }

sub merge {
    my ($self, $other) = @_;
    $self->{values} = Hash::Merge::Simple::merge(
        $self->_values,
        $other->_values,
    );
    return $self;
}

sub errors {
    my $self = shift;
    return +{ map {
        my $err = $self->_values->{$_}->[1];
        $err ? ( $_ => $err ) : ();
    } keys %{$self->_values} };
}

sub is_valid {
    my $self = shift;
    return all { $self->_values->{$_}->[0] } keys %{$self->_values};
}

package APISchema::Validator::Decoder;

# cpan
use JSON::XS qw(decode_json);
use URL::Encode qw(url_params_mixed);
use Class::Accessor::Lite ( new => 1 );

sub perl {
    my ($self, $body) = @_;
    return $body;
}

my $JSON = JSON::XS->new->utf8;
sub json {
    my ($self, $body) = @_;
    return $JSON->decode($body);
}

sub url_parameter {
    my ($self, $body) = @_;
    return url_params_mixed($body, 1);
}

package APISchema::Validator;

1;
__END__
