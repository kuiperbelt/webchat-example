use strict;
use warnings;
use utf8;
use Plack::Request;
use Router::Boom;
use HTML::Escape qw/escape_html/;
use Data::UUID;
use Redis::Fast;
use Furl;
use Path::Tiny;
use JSON::PP qw/decode_json encode_json/;
use Encode qw/encode_utf8 decode_utf8/;

my $redis = Redis::Fast->new;
my $furl = Furl->new;
my $router = Router::Boom->new;
my $uuid_generator = Data::UUID->new;

use constant {
    ENGINEIO_PACKET_TYPE => {
        open    => 0,
        close   => 1,
        ping    => 2,
        pong    => 3,
        message => 4,
        upgrade => 5,
        noop    => 6,
    },
    SOCKETIO_PACKET_TYPE => {
        connect      => 0,
        disconnect   => 1,
        event        => 2,
        ack          => 3,
        error        => 4,
        binary_event => 5,
        binary_ack   => 6,
    },
    PING_INTERVAL => 25000,
    PING_TIMEOUT  => 5000,
};

$router->add("/favicon.ico", sub {
    return ["404", [], []];
});

$router->add("/", sub {
    my $file = path("index.html")->slurp;
    return ["200", ["Content-Type" => "text/html"], [$file]];
});

$router->add("/connect", sub {
    my $env = shift;
    my $req = Plack::Request->new($env);

    my $endpoint = $req->header("X-Kuiperbelt-Endpoint");

    my $session = $uuid_generator->create_str;

    $redis->sadd("kuiperbelt_endpoints", $endpoint);
    $redis->set("kuiperbelt_endpoint:$session", $endpoint);
    $redis->sadd("kuiperbelt_sessions:$endpoint", $session);
    $redis->rpush("kuiperbelt_socketiostarting", $session);

    my $resp = ENGINEIO_PACKET_TYPE->{open} . encode_json({
        sid => $session,
        upgrades => [],
        pingInterval => PING_INTERVAL,
        pingTimeout  => PING_TIMEOUT,
    });

    $SIG{ALRM} = sub {
        while (my $session = $redis->lpop("kuiperbelt_socketiostarting")) {
            send_message($endpoint, ENGINEIO_PACKET_TYPE->{message} . SOCKETIO_PACKET_TYPE->{connect}, $session);
            $redis->set("kuiperbelt_socketiostarting:$session", 1);
        }
    };
    alarm 2;

    return ["200", ["X-Kuiperbelt-Session" => $session], [$resp]];
});

$router->add("/receive", sub {
    my $env = shift;
    my $req = Plack::Request->new($env);

    my $endpoint = $req->header("X-Kuiperbelt-Endpoint");
    my $session  = $req->header("X-Kuiperbelt-Session");
    my $msg      = $req->content;

    my $engineio_packet_type = substr($msg, 0, 1);
    if ($engineio_packet_type eq ENGINEIO_PACKET_TYPE->{ping}) {
        send_message($endpoint, ENGINEIO_PACKET_TYPE->{pong}, $session);
    }
    elsif ($engineio_packet_type eq ENGINEIO_PACKET_TYPE->{message}) {
        my $socketio_packet_type = substr($msg, 1, 1);
        if ($socketio_packet_type eq SOCKETIO_PACKET_TYPE->{event}) {
            my $message = substr($msg, 2);
            my $event = decode_json($message);
            if (ref $event eq "ARRAY" && scalar(@$event) == 2 && $event->[0] eq "message") {
                my $escaped_message = escape_html($event->[1]);
                my $engineio_message =
                    ENGINEIO_PACKET_TYPE->{message} .
                    SOCKETIO_PACKET_TYPE->{event} .
                    encode_json(["message", $escaped_message]);
                broadcast_message($engineio_message);
                $redis->rpush("messages", $escaped_message);
            }
            else {
                warn sprintf("unexpected event message structure: %s", $msg);
            }
        }
        elsif ($socketio_packet_type eq SOCKETIO_PACKET_TYPE->{connect}) {
            # nop
        }
        else {
            warn sprintf("not support Socket.IO message type: %s", $msg);
        }
    }
    else {
        warn sprintf("not support Engine.IO message type: %s", $msg);
    }

    if (!$redis->get("kuiperbelt_socketiostarting:$session")) {
        $redis->set("kuiperbelt_socketiostarting:$session", 1);
        send_message($endpoint, ENGINEIO_PACKET_TYPE->{message} . SOCKETIO_PACKET_TYPE->{connect}, $session);
    }

    return ["200", ["X-Kuiperbelt-Session" => $session], [""]];
});

$router->add("/close", sub {
    my $env = shift;
    my $req = Plack::Request->new($env);

    my $session = $req->header("X-Kuiperbelt-Session");

    my $endpoint_key = "kuiperbelt_endpoint:$session"; 
    if (my $endpoint = $redis->get($endpoint_key)) {
        $redis->srem("kuiperbelt_sessions:$endpoint", $session);
        $redis->del($endpoint_key, "kuiperbelt_socketiostarting:$session");
    }

    return ["200", [], ["success closed"]];
});

$router->add("/recent", sub {
    my $env = shift;
    my $req = Plack::Request->new($env);

    my @messages = $redis->lrange("messages", -20, -1);
    my $data = encode_json([map { decode_utf8($_) } @messages]);

    return ["200", ["Content-Type" => "application/json"], [$data]];
});

$router->add("/ws_endpoint", sub {
    my $env = shift;
    my $req = Plack::Request->new($env);

    my $endpoint = $ENV{KUIPERBELT_CONNECT_ENDPOINT} // "ws://localhost:12345/";
    my $data = encode_json({ endpoint => $endpoint });

    return ["200", ["Content-Type" => "application/json"], [$data]];
});

sub endpoint_map {
    my @endpoints = $redis->smembers("kuiperbelt_endpoints");
    my %endpoint_map;

    for my $endpoint (@endpoints) {
        my @sessions = $redis->smembers("kuiperbelt_sessions:$endpoint");
        next if scalar(@sessions) == 0;
        $endpoint_map{$endpoint} = \@sessions;
    }

    return \%endpoint_map;
}

my $kuiperbelt_api_protocol = $ENV{KUIPERBELT_API_PROTOCOL} // "http";

$router->add("/post", sub {
    my $env = shift;
    my $req = Plack::Request->new($env);

    my $message = $req->parameters->{message};
    $message = escape_html($message);
    return ["400", [], ["invalid post"]] if $message eq "";

    $redis->rpush("messages", $message);

    my $engineio_message =
        ENGINEIO_PACKET_TYPE->{message} .
        SOCKETIO_PACKET_TYPE->{event} .
        encode_json(["message", $message]);
    broadcast_message($engineio_message);

    return ["200", [], ["success post"]];
});

sub broadcast_message {
    my $message = shift;

    my $endpoint_map = endpoint_map();

    for my $endpoint (keys %$endpoint_map) {
        my $sessions = $endpoint_map->{$endpoint};

        send_message($endpoint, $message, @$sessions);
    }
}

sub send_message {
    my ($endpoint, $message, @sessions) = @_;

    my $resp = $furl->post(
        "$kuiperbelt_api_protocol://$endpoint/send",
        [map {; "X-Kuiperbelt-Session" => $_ } @sessions],
        $message,
    );
    my $data = eval { decode_json($resp->content) };
    if (my $err = $@) {
        warn $err;
        return;
    }
    my $errors = $data->{errors};
    return if !$errors || ref $errors ne "ARRAY";

    my @invalid_sessions = map { $_->{session} } @$errors;
    $redis->srem("kuiperbelt_sessions:$endpoint", @invalid_sessions);
    $redis->del(map { "kuiperbelt_endpoint:$_" } @invalid_sessions);
}


my $app = sub {
    my $env = shift;
    my ($dest) = $router->match($env->{PATH_INFO});
    $dest->($env);
};
