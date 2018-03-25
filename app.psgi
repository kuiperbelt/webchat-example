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
use JSON qw/decode_json encode_json/;
use Encode qw/encode_utf8 decode_utf8/;

my $redis = Redis::Fast->new;
my $furl = Furl->new;
my $router = Router::Boom->new;
my $uuid_generator = Data::UUID->new;

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

    return ["200", ["X-Kuiperbelt-Session" => $session], ["Hello! anonymous user"]];
});

$router->add("/close", sub {
    my $env = shift;
    my $req = Plack::Request->new($env);

    my $session = $req->header("X-Kuiperbelt-Session");

    my $endpoint_key = "kuiperbelt_endpoint:$session"; 
    if (my $endpoint = $redis->get($endpoint_key)) {
        $redis->srem("kuiperbelt_sessions:$endpoint", $session);
        $redis->del($endpoint_key);
    }

    return ["200", [], ["success closed"]];
});

$router->add("/recent", sub {
    my $env = shift;
    my $req = Plack::Request->new($env);

    my @messages = $redis->lrange("messages", 0, 20);
    my $data = encode_json([map { decode_utf8($_) } @messages]);

    return ["200", ["Content-Type" => "application/json"], [$data]];
});

$router->add("/ws_endpoint", sub {
    my $env = shift;
    my $req = Plack::Request->new($env);

    my @messages = $redis->lrange("messages", 0, 20);
    my $endpoint = $ENV{KUIPERBELT_CONNECT_ENDPOINT} // "ws://localhost:12345/connect";
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

    my $endpoint_map = endpoint_map();

    for my $endpoint (keys %$endpoint_map) {
        my $sessions = $endpoint_map->{$endpoint};

        my $resp = $furl->post(
            "$kuiperbelt_api_protocol://$endpoint/send",
            [map {; "X-Kuiperbelt-Session" => $_ } @$sessions],
            $message,
        );
        my $data = eval { decode_json($resp->content) };
        if (my $err = $@) {
            warn $err;
            next;
        }
        my $errors = $data->{errors};
        next if !$errors || ref $errors ne "ARRAY";

        my @invalid_sessions = map { $_->{session} } @$errors;
        $redis->srem("kuiperbelt_sessions:$endpoint", @invalid_sessions);
        $redis->del(map { "kuiperbelt_endpoint:$_" } @invalid_sessions);
    }

    return ["200", [], ["success post"]];
});


my $app = sub {
    my $env = shift;
    my ($dest) = $router->match($env->{PATH_INFO});
    $dest->($env);
};
