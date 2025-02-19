# File: Server.pm
#
# Purpose: Handles server-related IRC events.

# SPDX-FileCopyrightText: 2005-2023 Pragmatic Software <pragma78@gmail.com>
# SPDX-License-Identifier: MIT

package PBot::Core::Handlers::Server;

use PBot::Imports;
use parent 'PBot::Core::Class';

use PBot::Core::MessageHistory::Constants ':all';

use Time::HiRes qw/time/;

sub initialize($self, %conf) {
    $self->{pbot}->{event_dispatcher}->register_handler('irc.welcome',       sub { $self->on_welcome       (@_) });
    $self->{pbot}->{event_dispatcher}->register_handler('irc.disconnect',    sub { $self->on_disconnect    (@_) });
    $self->{pbot}->{event_dispatcher}->register_handler('irc.motd',          sub { $self->on_motd          (@_) });
    $self->{pbot}->{event_dispatcher}->register_handler('irc.notice',        sub { $self->on_notice        (@_) });
    $self->{pbot}->{event_dispatcher}->register_handler('irc.nick',          sub { $self->on_nickchange    (@_) });
    $self->{pbot}->{event_dispatcher}->register_handler('irc.isupport',      sub { $self->on_isupport      (@_) });
    $self->{pbot}->{event_dispatcher}->register_handler('irc.yourhost',      sub { $self->log_first_arg    (@_) });
    $self->{pbot}->{event_dispatcher}->register_handler('irc.created',       sub { $self->log_first_arg    (@_) });
    $self->{pbot}->{event_dispatcher}->register_handler('irc.luserconns',    sub { $self->log_first_arg    (@_) });
    $self->{pbot}->{event_dispatcher}->register_handler('irc.notregistered', sub { $self->log_first_arg    (@_) });
    $self->{pbot}->{event_dispatcher}->register_handler('irc.n_local',       sub { $self->log_third_arg    (@_) });
    $self->{pbot}->{event_dispatcher}->register_handler('irc.n_global',      sub { $self->log_third_arg    (@_) });
    $self->{pbot}->{event_dispatcher}->register_handler('irc.nononreg',      sub { $self->on_nononreg      (@_) });
    $self->{pbot}->{event_dispatcher}->register_handler('irc.chghost',       sub { $self->on_chghost       (@_) });
    $self->{pbot}->{event_dispatcher}->register_handler('irc.whoisuser',     sub { $self->on_whoisuser     (@_) });
    $self->{pbot}->{event_dispatcher}->register_handler('irc.whoishost',     sub { $self->on_whoishost     (@_) });
}

sub on_init($self, $conn, $event) {
    my (@args) = ($event->args);
    shift @args;
    $self->{pbot}->{logger}->log("*** @args\n");
    return 1;
}

sub on_welcome($self, $event_type, $event) {
    $self->{pbot}->{logger}->log($event->{args}[1] . "\n");

    if ($self->{pbot}->{irc_capabilities}->{sasl}) {
        # using SASL; go ahead and auto-join channels now
        $self->{pbot}->{logger}->log("Autojoining channels.\n");
        $self->{pbot}->{channels}->autojoin;
    }

    $self->{pbot}->{logger}->log("Getting self-WHOIS for $event->{args}[0] ...\n");
    $self->{pbot}->{conn}->whois($event->{args}[0]);
    return 1;
}

sub on_whoisuser($self, $event_type, $event) {
    my $nick = $event->{args}[1];
    my $user = $event->{args}[2];
    my $host = $event->{args}[3];

    my $botnick = $self->{pbot}->{conn}->nick;

    if ($nick eq $botnick) {
        $self->{pbot}->{hostmask} = "$nick!$user\@$host";
        $self->{pbot}->{logger}->log("Set hostmask to $self->{pbot}->{hostmask}\n");
    }
}

sub on_whoishost($self, $event_type, $event) {
    $self->{pbot}->{logger}->log("$event->{args}[1] $event->{args}[2]\n");
}

sub on_disconnect($self, $event_type, $event) {
    $self->{pbot}->{logger}->log("Disconnected...\n");
    $self->{pbot}->{conn} = undef;

    # send pbot.disconnect to notify PBot internals
    $self->{pbot}->{event_dispatcher}->dispatch_event(
        'pbot.disconnect', undef
    );

    # attempt to reconnect to server
    # TODO: maybe add a registry entry to control whether the bot auto-reconnects
    $self->{pbot}->connect;

    return 1;
}

sub on_motd($self, $event_type, $event) {
    if ($self->{pbot}->{registry}->get_value('irc', 'show_motd')) {
        my $from = $event->{from};
        my $msg  = $event->{args}[1];
        $self->{pbot}->{logger}->log("MOTD from $from :: $msg\n");
    }

    return 1;
}

sub on_notice($self, $event_type, $event) {
    my ($server, $to, $text) = (
        $event->nick,
        $event->to,
        $event->{args}[0],
    );

    # don't handle non-server NOTICE
    return undef if $to ne '*';

    # log notice
    $self->{pbot}->{logger}->log("NOTICE from $server: $text\n");

    return 1;
}

sub on_isupport($self, $event_type, $event) {
    # remove and discard first and last arguments
    # (first arg is botnick, last arg is "are supported by this server")
    shift @{$event->{args}};
    pop   @{$event->{args}};

    my $logmsg = "$event->{from} supports:";

    foreach my $arg (@{$event->{args}}) {
        my ($key, $value) = split /=/, $arg;

        if ($key =~ s/^-//) {
            # server removed suppport for this key
            delete $self->{pbot}->{isupport}->{$key};
        } else {
            $self->{pbot}->{isupport}->{$key} = $value // 1;
        }

        $logmsg .= defined $value ? " $key=$value" : " $key";
    }

    $self->{pbot}->{logger}->log("$logmsg\n");

    return 1;
}

sub on_nickchange($self, $event_type, $event) {
    my ($nick, $user, $host, $newnick) = ($event->nick, $event->user, $event->host, $event->args);

    ($nick, $user, $host) = $self->{pbot}->{irchandlers}->normalize_hostmask($nick, $user, $host);

    $self->{pbot}->{logger}->log("[NICKCHANGE] $nick!$user\@$host changed nick to $newnick\n");

    if ($newnick eq $self->{pbot}->{registry}->get_value('irc', 'botnick')) {
        if (not $self->{pbot}->{joined_channels}) {
            $self->{pbot}->{channels}->autojoin;
        }

        $self->{pbot}->{hostmask} = "$newnick!$user\@$host";
        $self->{pbot}->{logger}->log("Set hostmask to $self->{pbot}->{hostmask}\n");
        return 1;
    }

    my $message_account = $self->{pbot}->{messagehistory}->{database}->get_message_account($nick, $user, $host);
    $self->{pbot}->{messagehistory}->{database}->devalidate_all_channels($message_account, $self->{pbot}->{antiflood}->NEEDS_CHECKBAN);
    my $channels = $self->{pbot}->{nicklist}->get_channels($newnick);
    foreach my $channel (@$channels) {
        next if $channel !~ m/^#/;
        $self->{pbot}->{messagehistory}->add_message($message_account, "$nick!$user\@$host", $channel, "NICKCHANGE $newnick", MSG_NICKCHANGE);
    }
    $self->{pbot}->{messagehistory}->{database}->update_hostmask_data("$nick!$user\@$host", {last_seen => scalar time});

    my $newnick_account = $self->{pbot}->{messagehistory}->{database}->get_message_account($newnick, $user, $host, $nick);
    $self->{pbot}->{messagehistory}->{database}->devalidate_all_channels($newnick_account, $self->{pbot}->{antiflood}->NEEDS_CHECKBAN);
    $self->{pbot}->{messagehistory}->{database}->update_hostmask_data("$newnick!$user\@$host", {last_seen => scalar time});

    $self->{pbot}->{antiflood}->check_flood(
        "$nick!$user\@$host", $nick, $user, $host, "NICKCHANGE $newnick",
        $self->{pbot}->{registry}->get_value('antiflood', 'nick_flood_threshold'),
        $self->{pbot}->{registry}->get_value('antiflood', 'nick_flood_time_threshold'),
        MSG_NICKCHANGE,
    );

    return 1;
}

sub on_nononreg($self, $event_type, $event) {
    my $target = $event->{args}[1];

    $self->{pbot}->{logger}->log("Cannot send private /msg to $target; they are blocking unidentified /msgs.\n");

    return 1;
}

sub on_chghost($self, $event_type, $event) {
    my $nick    = $event->nick;
    my $user    = $event->user;
    my $host    = $event->host;
    my $newuser = $event->{args}[0];
    my $newhost = $event->{args}[1];

    ($nick, $user,    $host)    = $self->{pbot}->{irchandlers}->normalize_hostmask($nick, $user,    $host);
    ($nick, $newuser, $newhost) = $self->{pbot}->{irchandlers}->normalize_hostmask($nick, $newuser, $newhost);

    my $account = $self->{pbot}->{messagehistory}->{database}->get_message_account($nick, $user, $host);

    my $id = $self->{pbot}->{messagehistory}->{database}->get_message_account_id("$nick!$newuser\@$newhost");

    if (defined $id) {
        if ($id != $account) {
            $self->{pbot}->{messagehistory}->{database}->link_alias($account, $id, LINK_STRONG);
        }
    } else {
        $id = $self->{pbot}->{messagehistory}->{database}->add_message_account("$nick!$newuser\@$newhost", $account, LINK_STRONG);
    }

    $self->{pbot}->{logger}->log("[CHGHOST] ($account) $nick!$user\@$host changed host to ($id) $nick!$newuser\@$newhost\n");

    if ("$nick!$user\@$host" eq $self->{pbot}->{hostmask}) {
        $self->{pbot}->{logger}->log("Set hostmask to $nick!$newuser\@$newhost\n");
        $self->{hostmask} = "$nick!$newuser\@$newhost";
    }

    my $channels = $self->{pbot}->{nicklist}->get_channels($nick);

    foreach my $channel (@$channels) {
        $self->{pbot}->{antiflood}->check_bans($id, "$nick!$newuser\@$newhost", $channel);
    }

     return 1;
}

sub log_first_arg($self, $event_type, $event) {
    $self->{pbot}->{logger}->log("$event->{args}[1]\n");
    return 1;
}

sub log_third_arg($self, $event_type, $event) {
    $self->{pbot}->{logger}->log("$event->{args}[3]\n");
    return 1;
}

1;
