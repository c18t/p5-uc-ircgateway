package Uc::IrcGateway::Connection;

use 5.014;
use warnings;
use utf8;

use parent qw(AnyEvent::Handle);

use Uc::IrcGateway::Structure;

use Carp ();
use Path::Class qw(file);
use Scalar::Util qw(refaddr);

use Class::Accessor::Lite (
    rw => [qw(self)],
    ro => [ qw(
        ircd
        schema

        options
        users
        channels
    )],
);

sub new {
    my $class = shift;
    my %args = @_ == 1 ? %{$_[0]} : @_;

    my $self = $class->SUPER::new(
        self => undef,
        ircd => undef,
        schema => Uc::IrcGateway::Structure->new( dbh => setup_dbh() ),

        options => {},
        users => {},
        channels => {},

        registered => 0,

        %args,
    );

    $self->schema->setup_database;

    $self;
}

sub create_user {
    my $self = shift;
    my %args = @_ == 1 ? %{$_[0]} : @_;
    $self->schema->insert('user', \%args);
}

sub has_nick {
    my ($self, $nick) = @_;
    $self->schema->single('user', { nick => $nick }) ? 1 : 0;
}

sub lookup {
    my ($self, $nick) = @_;
    my $user = $self->schema->single('user', { nick => $nick });
    $user ? $user->login : undef;
}

1; # Magic true value required at end of module
__END__

=head1 NAME

Uc::IrcGateway::Connection - Uc::IrcGatewayのためのコネクションクラス


=head1 DESCRIPTION


=head1 INTERFACE


=head1 INCOMPATIBILITIES

None reported.


=head1 BUGS AND LIMITATIONS

Please report any bugs or feature requests to
L<https://github.com/UCormorant/p5-uc-ircgateway/issues>


=head1 SEE ALSO

=item L<Uc::IrcGateway>


=head1 AUTHOR

U=Cormorant  C<< <u@chimata.org> >>


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2011-2013, U=Cormorant C<< <u@chimata.org> >>. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.


=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.
