package Uc::IrcGateway::TempUser;

use 5.014;
use warnings;
use utf8;

use Carp qw(croak);
use Path::Class qw(file);
use Uc::IrcGateway::Structure;

our %MODE_TABLE;
our @USER_PROP;

BEGIN {
    our %MODE_TABLE = (
        away           => 'a', # Away
        invisible      => 'i', # Invisible
        allow_wallops  => 'w', # allow Wallops receiving
        allow_s_notice => 's', # allow Server notice receiving
        restricted     => 'r', # Restricted user connection
        operator       => 'o', # Operator flag
        local_operator => 'O', # local Operator flag
    );
    our @USER_PROP = (qw(
        login nick password realname host addr server
        userinfo away_message last_modified
    ), sort keys %MODE_TABLE);
}
use Class::Accessor::Lite rw => \@USER_PROP;

# constructer

sub new {
    my $class = shift;
    my %args = @_ == 1 ? %{$_[0]} : @_;

    bless +{
        %args,
    }, $class;
}

# other method

sub register {
    my ($self, $handle) = @_;

    croak "user registration error: nick is not defined"  if not $self->nick;
    croak "user registration error: login is not defined" if not $self->login;

    my $db = file($handle->ircd->app_dir, sprintf "%s.sqlite", $self->login);
    my $exists_db = -e $db;
    $handle->schema->{dbh} = setup_dbh($db);
    $handle->schema->setup_database if not $exists_db;

    my $user;
    if ($user = $handle->get_users($self->login)) {
        $user->update($self->user_prop);
    }
    else {
        $user = $handle->set_user($self->user_prop);
    }
    $handle->self($user);
    map { $_->part_users($handle->self->login) } $handle->self->channels;

    $user;
}

sub to_prefix {
    sprintf "%s!%s@%s", "*", "*", "*";
}

sub user_prop {
    +{ map { defined $_[0]{$_} ? ($_ => $_[0]{$_}) : () } @USER_PROP };
}

sub mode_string {
    join '', map { $_[0]->{$_} ? $MODE_TABLE{$_} : () } sort keys @{$_[0]}{keys %MODE_TABLE};
}


1; # Magic true value required at end of module
__END__

=head1 NAME

Uc::IrcGateway::TempUser - Temporary User Object for Uc::IrcGateway


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
