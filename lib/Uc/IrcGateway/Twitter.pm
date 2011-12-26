package Uc::IrcGateway::Twitter;

use 5.010;
use common::sense;
use warnings qw(utf8);
use Encode qw(decode find_encoding);
use Any::Moose;
use Any::Moose qw(::Util::TypeConstraints);
use Uc::IrcGateway;
use Net::Twitter::Lite;
use AnyEvent::Twitter::Stream;
use HTML::Entities qw(decode_entities);
use DateTime::Format::DateParse;
use Config::Pit;

use Data::Dumper;
use Smart::Comments;

$Data::Dumper::Indent = 0;

use Readonly;
Readonly my $CHARSET => 'utf8';

our $VERSION = $Uc::IrcGateway::VERSION;
our $CRLF = "\015\012";
our %IRC_COMMAND_EVENT = %Uc::IrcGateway::IRC_COMMAND_EVENT;
my  $encode = find_encoding($CHARSET);

extends 'Uc::IrcGateway';
subtype 'ValidChanName' => as 'Str' => where { /^[#&][^\s,]+$/ } => message { "This Str ($_) is not a valid channel name!" };
has '+port' => ( default => 16668 );
has '+gatewayname' => ( default => 'twitterircgateway' );
has 'stream_channel' => ( is => 'rw', isa => 'ValidChanName', default => '#twitter' );
has 'activity_channel' => ( is => 'rw', isa => 'ValidChanName', default => '#activity' );
has 'conf_app' => ( is  => 'rw', isa => 'HashRef', required => 1 );

sub BUILDARGS {
    my ($class, %args) = @_;
    $args{conf_app} = {
        consumer_key => $args{consumer_key},
        consumer_secret => $args{consumer_secret},
    };
    return \%args;
}

sub BUILD {
    no strict 'refs';
    my $self = shift;
    for my $cmd (qw/user join part privmsg favorite unfavorite delete reply retweet unoretweet pin quit/) {
        $IRC_COMMAND_EVENT{$cmd} = \&{"_event_$cmd"};
    }
    $self->reg_cb( %IRC_COMMAND_EVENT,
        on_eof => sub {
            my ($self, $handle) = @_;
            undef $handle;
        },
        on_error => sub {
            my ($self, $handle, $message) = @_;
#            warn $_[2];
        },
    );
}

override '_event_user' => sub {
    my ($self, $msg, $handle) = super();
    return unless $self;

    my %opt = _opt_parser($handle->self->realname);
    $handle->options(\%opt);
    $handle->options->{account} ||= $handle->self->nick;
    $handle->options->{mention_count} ||= 20;
    $handle->options->{include_rts} ||= 0;
    if (!$handle->options->{stream} ||
        not $self->check_channel_name($handle, $handle->options->{stream})) {
            $handle->options->{stream} = $self->stream_channel;
    }
    if (!$handle->options->{activity} ||
        not $self->check_channel_name($handle, $handle->options->{activity})) {
            $handle->options->{activity} = $self->activity_channel;
    }
    if ($handle->options->{consumer}) {
        @{$handle->{conf_app}}{qw/consumer_key consumer_secret/} = split /:/, $handle->options->{consumer};
    }
    else {
        $handle->{conf_app} = $self->conf_app;
    }

    my $conf = $self->servername.'.'.$handle->options->{account};
    $handle->{conf_user} = pit_get( $conf );
    $handle->{lookup} = delete $handle->{conf_user}{lookup} || {};
    $handle->{tmap} = tie @{$handle->{timeline}}, 'Uc::IrcGateway::Util::TypableMap', shuffled => 1;
    $handle->channels( delete $handle->{conf_user}{channels} || {} );

    $self->twitter_agent($handle);
};

override '_event_join' => sub {
    my ($self, $msg, $handle) = super();
    return unless $self;

    my $nt   = $handle->{nt};
    my $tmap = $handle->{tmap};
    my $stream_channel   = $handle->options->{stream};
    my $activity_channel = $handle->options->{activity};

    for my $chan (split /,/, $msg->{params}[0]) {
        next unless $self->check_channel_name( $handle, $chan, joined => 1 );

        if ($chan eq $stream_channel) {
            $self->streamer(
                handle          => $handle,
                consumer_key    => $handle->{conf_app}{consumer_key},
                consumer_secret => $handle->{conf_app}{consumer_secret},
                token           => $handle->{conf_user}{token},
                token_secret    => $handle->{conf_user}{token_secret},
            );

            eval {
                my $user = $nt->show_user($handle->self->{login});
                my $status = delete $user->{status};
                $status->{user} = $user;

                $status->{text} ||= '';
                (my $text = $encode->encode(decode_entities($status->{text}))) =~ s/[\r\n]+/ /g;
                $self->handle_msg(parse_irc_msg("TOPIC $stream_channel :$text [$tmap]"), $handle);
                push @{$handle->{timeline}}, $status;
            };
            if ($@) { $self->send_cmd( $handle, $self->daemon, 'NOTICE', $stream_channel, qq|topic fetching error: $@| ); }
        }
        elsif ($chan eq $activity_channel) {
            eval {
                my $mentions = $nt->mentions({
                    count => $handle->options->{mention_count},
                    include_rts => $handle->options->{include_rts},
                });

                for my $mention (reverse @$mentions) {
                    my ($nick, $real) = @{$mention->{user}}{qw/screen_name id/};
                    next unless $nick and $mention->{text};

                    $mention->{text}       ||= '';
                    $mention->{user}{name} ||= '';
                    $mention->{user}{url}  ||= '';
                    (my $text = $encode->encode(decode_entities($mention->{text})))       =~ s/[\r\n]+/ /g;
                    (my $name = $encode->encode(decode_entities($mention->{user}{name}))) =~ s/[\r\n]+/ /g;
                    (my $url  = $encode->encode(decode_entities($mention->{user}{url})))  =~ s/[\r\n]+/ /g;
                    $url =~ s/\s/+/g; $url ||= "http://twitter.com/$nick";

                    my $stream_channel = $handle->options->{stream};
                    if ($handle->has_channel($stream_channel) and defined $real) {
                        my $oldnick = $handle->{lookup}{$real} || '';
                        my $channel = $handle->get_channels($stream_channel);

                        my $user;
                        if (!$oldnick || !$channel->has_user($oldnick)) {
                            $user = Uc::IrcGateway::Util::User->new(
                                nick => $nick, login => $real, realname => $name,
                                host => 'twitter.com', addr => '127.0.0.1', server => $url,
                            );
                            $self->send_cmd( $handle, $user, 'JOIN', $stream_channel );
                            $channel->set_users($nick => $user);
                        }
                        else {
                            $user = $channel->get_users($oldnick);
                            if ($oldnick ne $nick) {
                                $self->send_cmd( $handle, $user, 'NICK', $nick );
                                for my $chan ($handle->who_is_channel($oldnick)) {
                                    $chan->get_users($oldnick)->nick($nick);
                                }
                            }
                        }

                        $self->send_cmd( $handle, $user, 'PRIVMSG', $activity_channel, "$text [$tmap]" );
                        push @{$handle->{timeline}}, $mention;
                    }
                }
            };
            if ($@) { $self->send_cmd( $handle, $self->daemon, 'NOTICE', $activity_channel, qq|mention fetching error: $@| ); }
        }
    }
};

override '_event_part' => sub {
    my ($self, $msg, $handle) = super();
    return unless $self;

    my ($chans, $text) = @{$msg->{params}};

    for my $chan (split /,/, $chans) {
        delete $handle->{streamer} if $chan eq $handle->options->{stream};
    }
};

override '_event_privmsg' => sub {
    my ($self, $msg, $handle) = _check_params(@_);
    return unless $self;

    my ($chan, $text) = @{$msg->{params}};
    return () unless $self->check_channel_name( $handle, $chan, enable => 1 );

    if ($text =~ /^\s+(\w+)(?:\s+(.*))?/) {
        my ($cmd, $arg) = ($1, $2); $arg ||= '';
        if ($cmd =~ /^re(?:ply)?$/) {
            my ($tid, $text) = split /\s+/, $arg, 2; $text ||= '';
            $self->handle_msg(parse_irc_msg("REPLY $tid :$text"), $handle); return ();
        }
        if ($cmd =~ /^f(?:av(?:ou?rites?)?)?$/)   { $self->handle_msg(parse_irc_msg("FAVORITE $arg"),   $handle); return (); }
        if ($cmd =~ /^unf(?:av(?:ou?rites?)?)?$/) { $self->handle_msg(parse_irc_msg("UNFAVORITE $arg"), $handle); return (); }
        if ($cmd =~ /^o+ps!*$|^del(?:ete)?$/)     { $self->handle_msg(parse_irc_msg("DELETE $arg"),     $handle); return (); }
        if ($cmd =~ /^or(?:etwee)?t$/)            { $self->handle_msg(parse_irc_msg("RETWEET $arg"),    $handle); return (); }
        if ($cmd =~ /^r(?:etwee)?t$/)             { $self->handle_msg(parse_irc_msg("UNORETWEET $arg"), $handle); return (); }
#        if ($cmd =~ /^me(?:ntion)?$/)            { $self->handle_msg(parse_irc_msg("MENTION $arg"), $handle);  return (); }
    }

    my $nt = $self->twitter_agent($handle);
    my $w; $w = AnyEvent->timer( after => 0.5, cb => sub {
        eval { $nt->update($encode->decode($text)); };
        if ($@) { $self->send_cmd( $handle, $self->daemon, 'NOTICE', $handle->options->{stream}, qq|send error: "$text": $@| ); }
        undef $w;
    } );
};

sub _event_reply {
    my ($self, $msg, $handle) = _check_params(@_);
    return unless $self;

    my ($tid, $text) = @{$msg->{params}};
    my $tweet = $handle->{tmap}->get($tid);
    my $nt = $self->twitter_agent($handle);
    my $w; $w = AnyEvent->timer( after => 0.5, cb => sub {
        eval { $nt->update({ status => $encode->decode("\@$tweet->{user}{screen_name} $text"), in_reply_to_status_id => $tweet->{id} }); };
        if ($@) { $self->send_cmd($handle, $self->daemon, 'NOTICE', $handle->options->{stream}, "reply error: $@"); }
        undef $w;
    } );
}

sub _event_favorite {
    my ($self, $msg, $handle) = _check_params(@_);
    return unless $self;

    my $nt = $self->twitter_agent($handle);
    my $w; $w = AnyEvent->timer( after => 0.5, cb => sub {
        for my $tid (@{$msg->{params}}) {
            $self->tid_event($handle, 'fav', $tid, sub { $nt->create_favorite(shift) });
        }
        undef $w;
    } );
}

sub _event_unfavorite {
    my ($self, $msg, $handle) = _check_params(@_);
    return unless $self;

    my $nt = $self->twitter_agent($handle);
    my $w; $w = AnyEvent->timer( after => 0.5, cb => sub {
        for my $tid (@{$msg->{params}}) {
            $self->tid_event($handle, 'unfav', $tid, sub { $nt->destroy_favorite(shift) });
        }
        undef $w;
    } );
}

sub _event_retweet {
    my ($self, $msg, $handle) = _check_params(@_);
    return unless $self;

    my $nt = $self->twitter_agent($handle);
    my $w; $w = AnyEvent->timer( after => 0.5, cb => sub {
        for my $tid (@{$msg->{params}}) {
            $self->tid_event($handle, 'retweet', $tid, sub { $nt->retweet(shift) });
        }
        undef $w;
    } );
}

sub _event_unoretweet {
    my ($self, $msg, $handle) = _check_params(@_);
    return unless $self;

    my ($tid, $text) = @{$msg->{params}};
    my $nt = $self->twitter_agent($handle);
    my $tweet = $handle->{tmap}->get($tid);
    (my $notice = $encode->encode(decode_entities($tweet->{text}))) =~ s/[\r\n]+/ /g;

    $text   = $text ? $text.' ' : '';
    $notice = $text."RT \@$tweet->{user}{screen_name}: $notice";
    $notice =~ s/....$/.../ while length $notice > 140;

    my $w; $w = AnyEvent->timer( after => 0.5, cb => sub {
        eval { $nt->update({ status => $encode->decode($notice), in_reply_to_status_id => $tweet->{id} }); };
        if ($@) { $self->send_cmd($handle, $self->daemon, 'NOTICE', $handle->options->{stream}, "reply error: $@"); }
        undef $w;
    } );
}

sub _event_delete {
    my ($self, $msg, $handle) = @_;

    my $nt = $self->twitter_agent($handle);
    my @tids = @{$msg->{params}};
       @tids = $handle->get_channels($handle->options->{stream})->topic =~ /\[(.+?)\]$/ if not scalar @tids;
    my $w; $w = AnyEvent->timer( after => 0.5, cb => sub {
        for my $tid (@tids) {
            $self->tid_event($handle, 'delete', $tid, sub { $nt->destroy_status(shift) });
        }
        undef $w;
    } );
}

sub _event_pin {
    my ($self, $msg, $handle) = _check_params(@_);
    my $pin = $msg->{params}[0];

    $self->twitter_agent($handle, $pin);
    my $conf = $self->servername.'.'.$handle->options->{account};
    pit_set( $conf, data => {
        %{$handle->{conf_user}},
        lookup   => $handle->{lookup},
        channels => $handle->channels,
    } ) if $handle->{nt}{config_updated};
};

sub _event_quit {
    my ($self, $msg, $handle) = @_;
    my $conf = $self->servername.'.'.$handle->options->{account};
    pit_set( $conf, data => {
        %{$handle->{conf_user}},
        lookup   => $handle->{lookup},
        channels => $handle->channels,
    } );
    undef $handle;
};

sub tid_event {
    my ($self, $handle, $event, $tid, $cb) = @_;
    my $tweet = $handle->{tmap}->get($tid);
    my $text = '';

    if (!$tweet) { $text = "$event error: no such tid"; }
    else {
        eval { $cb->($tweet->{id}); };
        if ($@) { $text = "$event error: $@"; }
        else    {
            ($text = $encode->encode(decode_entities($tweet->{text}))) =~ s/[\r\n]+/ /g;
            $event =~ s/e$//;
            $text = "${event}ed: $tweet->{user}{screen_name}: $text";
        }
    }
    $self->send_cmd( $handle, $self->daemon, 'NOTICE', $handle->options->{stream}, "$text [$tid]" );
}

sub _opt_parser { my %opt; $opt{$1} = $2 while $_[0] =~ /(?:(\w+)=(\S+))/g; %opt }

sub join_channels {
    my ($self, $handle, $retry) = @_;
    my $nt = $handle->{nt};

    my $lists = eval { $nt->all_lists(); };
    $retry ||= 5 + 1;

    if ($@ && --$retry) {
        my $time = 10;
        my $text = "list fetching error (you will retry after $time sec): $@";
        $self->send_cmd( $handle, $self->daemon, 'NOTICE', $handle->options->{stream}, $text);
        my $w; $w = AnyEvent->timer( after => $time, cb => sub {
            $self->join_channels($handle, $retry);
            undef $w;
        } );
    }
    else {
        $self->handle_msg(parse_irc_msg('JOIN '.$handle->options->{stream}), $handle);
        $self->handle_msg(parse_irc_msg('JOIN '.$handle->options->{activity}), $handle);

        for my $list (@$lists) {
            next if $list->{user}{id} ne $handle->self->login;

            $list->{description} ||= '';
            (my $text = $encode->encode(decode_entities($list->{description}))) =~ s/[\r\n]+/ /g;
            my $chan = '#'.$list->{slug};
            my @users;
            my $page = -1;
            while ($page != 0) {
                my $res = eval { $nt->list_members({
                    user => $list->{user}{screen_name},
                    list_id => $list->{slug}, cursor => $page,
                }); };
                warn $@ and sleep 5 and next if $@;

                push @users, @{$res->{users}};
                $page = $res->{next_cursor};
            }

            for my $u (@users) {
                my ($nick, $real) = @{$u}{qw/screen_name id/};

                $u->{name} ||= '';
                $u->{url}  ||= '';
                (my $name = $encode->encode(decode_entities($u->{name}))) =~ s/[\r\n]+/ /g;
                (my $url  = $encode->encode(decode_entities($u->{url})))  =~ s/[\r\n]+/ /g;
                $url =~ s/\s/+/g; $url ||= "http://twitter.com/$nick";
                my $user = Uc::IrcGateway::Util::User->new(
                    nick => $nick, login => $real, realname => $name,
                    host => 'twitter.com', addr => '127.0.0.1', server => $url,
                );
                $handle->set_channels($chan => Uc::IrcGateway::Util::Channel->new) if !$handle->has_channel($chan);
                $handle->get_channels($chan)->set_users($nick => $user);
            }

            $self->handle_msg(parse_irc_msg("JOIN $chan"), $handle);
            $self->handle_msg(parse_irc_msg("TOPIC $chan :$text"), $handle);
        }
    }
}

sub twitter_agent {
    my ($self, $handle, $pin) = @_;
    return $handle->{nt} if defined $handle->{nt} && $handle->{nt}{authorized};

    my ($conf_app, $conf_user) = @{$handle}{qw/conf_app conf_user/};
    if (ref $handle->{nt} ne 'Net::Twitter::Lite') {
        $handle->{nt} = Net::Twitter::Lite->new(%$conf_app);
    }

    my $nt = $handle->{nt};
    $nt->access_token($conf_user->{token});
    $nt->access_token_secret($conf_user->{token_secret});

    if ($pin) {
        eval {
            @{$conf_user}{qw/token token_secret user_id screen_name/} = $nt->request_access_token(verifier => $pin);
            $nt->{config_updated} = 1;
        };
        if ($@) {
            $self->send_msg( $handle, ERR_YOUREBANNEDCREEP, "twitter authorization error: $@" );
        }
    }
    if ($nt->{authorized} = eval { $nt->account_totals; }) {
        my $user = $handle->self;
        $user->login($conf_user->{user_id});
        $user->host('twitter.com');
        $self->join_channels($handle);
    }
    else {
        $self->send_msg($handle, 'NOTICE', 'please open the following url and allow this app, then enter /PIN {code}.');
        $self->send_msg($handle, 'NOTICE', $nt->get_authorization_url);
    }

    return ();
}

sub streamer {
    my ($self, %config) = @_;
    my $handle = delete $config{handle};
    return $handle->{streamer} if exists $handle->{streamer};

    my $tmap = $handle->{tmap};
    $handle->{streamer} = AnyEvent::Twitter::Stream->new(
        method  => 'userstream',
        timeout => 45,
        %config,

        on_connect => sub {
            $self->send_cmd( $handle, $self->daemon, 'NOTICE', $handle->options->{stream}, 'streamer start to read.' );
        },
        on_eof => sub {
            $self->send_cmd( $handle, $self->daemon, 'NOTICE', $handle->options->{stream}, 'streamer stop to read.' );
            delete $handle->{streamer};
            $self->streamer(handle => $handle, %config);
        },
        on_error => sub {
            warn "error: $_[0]";
            delete $handle->{streamer};
            $self->streamer(handle => $handle, %config);
        },
        on_event => sub {
            my $event = shift;
            my $happen = $event->{event};
            my $source = $event->{source};
            my $target = $event->{target};
            my $tweet  = $event->{target_object} || {};

            if ($target->{id} == $handle->self->login) {
                my $text = '';
                if ($tweet->{text} ||= '') {
                    ($text = $encode->encode(decode_entities($tweet->{text}))) =~ s/[\r\n]+/ /g;
                    my $dt = DateTime::Format::DateParse->parse_datetime($tweet->{created_at});
                    $dt->set_time_zone( $self->time_zone );
                    $text .= " ($dt/$tweet->{id})";
                }
                my $notice = "$happen $target->{screen_name}".($text ? ": $text" : "");
                $self->send_cmd( $handle, $source->{screen_name}, 'NOTICE', $handle->options->{stream}, $notice );
            }
        },
        on_tweet => sub {
            my $tweet = shift;
            my $real = $tweet->{user}{id};
            my $nick = $tweet->{user}{screen_name};
            return unless $nick and $tweet->{text};

            $tweet->{text}       ||= '';
            $tweet->{user}{name} ||= '';
            $tweet->{user}{url}  ||= '';
            (my $text = $encode->encode(decode_entities($tweet->{text})))       =~ s/[\r\n]+/ /g;
            (my $name = $encode->encode(decode_entities($tweet->{user}{name}))) =~ s/[\r\n]+/ /g;
            (my $url  = $encode->encode(decode_entities($tweet->{user}{url})))  =~ s/[\r\n]+/ /g;
            $url =~ s/\s/+/g; $url ||= "http://twitter.com/$nick";

            my $stream_channel = $handle->options->{stream};
            if ($handle->has_channel($stream_channel) and defined $real) {
                my $oldnick = $handle->{lookup}{$real} || '';
                my $channel = $handle->get_channels($stream_channel);

                my $user;
                if (!$oldnick || !$channel->has_user($oldnick)) {
                    $user = Uc::IrcGateway::Util::User->new(
                        nick => $nick, login => $real, realname => $name,
                        host => 'twitter.com', addr => '127.0.0.1', server => $url,
                    );
                    $self->send_cmd( $handle, $user, 'JOIN', $stream_channel );
                    $channel->set_users($nick => $user);
                }
                else {
                    $user = $channel->get_users($oldnick);
                    if ($oldnick ne $nick) {
                        $self->send_cmd( $handle, $user, 'NICK', $nick );
                        for my $chan ($handle->who_is_channel($oldnick)) {
                            $chan->get_users($oldnick)->nick($nick);
                        }
                    }
                }

                if ($nick eq $handle->self->nick) {
                    $channel->topic("$text [$tmap]");
                    $self->send_cmd( $handle, $user, 'TOPIC', $stream_channel, "$text [$tmap]" );
                }
                else {
                    for my $chan ($handle->who_is_channel($nick)) {
                        $self->send_cmd( $handle, $user, 'PRIVMSG', $chan, "$text [$tmap]" );
                    }
                }

                $user->last_modified(time);
                $handle->{lookup}{$real} = $nick;
                push @{$handle->{timeline}}, $tweet;
            }
        },
    );
}

__PACKAGE__->meta->make_immutable;
no Any::Moose;


1; # Magic true value required at end of module
__END__

=head1 NAME

Uc::IrcGateway::Twitter - [One line description of module's purpose here]


=head1 VERSION

This document describes Uc::IrcGateway::Twitter version 0.0.1


=head1 SYNOPSIS

    use Uc::IrcGateway::Twitter;

=for author to fill in:
    Brief code example(s) here showing commonest usage(s).
    This section will be as far as many users bother reading
    so make it as educational and exeplary as possible.
  
  
=head1 DESCRIPTION

=for author to fill in:
    Write a full description of the module and its features here.
    Use subsections (=head2, =head3) as appropriate.


=head1 INTERFACE 

=for author to fill in:
    Write a separate section listing the public components of the modules
    interface. These normally consist of either subroutines that may be
    exported, or methods that may be called on objects belonging to the
    classes provided by the module.


=head1 DIAGNOSTICS

=for author to fill in:
    List every single error and warning message that the module can
    generate (even the ones that will "never happen"), with a full
    explanation of each problem, one or more likely causes, and any
    suggested remedies.

=over

=item C<< Error message here, perhaps with %s placeholders >>

[Description of error here]

=item C<< Another error message here >>

[Description of error here]

[Et cetera, et cetera]

=back


=head1 CONFIGURATION AND ENVIRONMENT

=for author to fill in:
    A full explanation of any configuration system(s) used by the
    module, including the names and locations of any configuration
    files, and the meaning of any environment variables or properties
    that can be set. These descriptions must also include details of any
    configuration language used.
  
Uc::IrcGateway::Twitter requires no configuration files or environment variables.


=head1 DEPENDENCIES

=for author to fill in:
    A list of all the other modules that this module relies upon,
    including any restrictions on versions, and an indication whether
    the module is part of the standard Perl distribution, part of the
    module's distribution, or must be installed separately. ]

None.


=head1 INCOMPATIBILITIES

=for author to fill in:
    A list of any modules that this module cannot be used in conjunction
    with. This may be due to name conflicts in the interface, or
    competition for system or program resources, or due to internal
    limitations of Perl (for example, many modules that use source code
    filters are mutually incompatible).

None reported.


=head1 BUGS AND LIMITATIONS

=for author to fill in:
    A list of known problems with the module, together with some
    indication Whether they are likely to be fixed in an upcoming
    release. Also a list of restrictions on the features the module
    does provide: data types that cannot be handled, performance issues
    and the circumstances in which they may arise, practical
    limitations on the size of data sets, special cases that are not
    (yet) handled, etc.

No bugs have been reported.

Please report any bugs or feature requests to
C<bug-uc-ircgateway-twitter@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.


=head1 AUTHOR

U=Cormorant  C<< <u@chimata.org> >>


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2011, U=Cormorant C<< <u@chimata.org> >>. All rights reserved.

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
