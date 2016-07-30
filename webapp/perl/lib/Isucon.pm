package Isucon;

use strict;
use warnings;
use utf8;
use Kossy;
use DBI;
use JSON;
use Cache::Memcached::Fast::Safe;
use Data::MessagePack;
use Compress::LZ4 ();

our $VERSION = 0.01;
my $articles_cache = {};
my $comments_cache = {};

{
    my $msgpack = Data::MessagePack->new->utf8;
    sub _message_pack   { $msgpack->pack(@_)   }
    sub _message_unpack { $msgpack->unpack(@_) }
    sub _compress_lz4   { ${$_[1]} = Compress::LZ4::compress(${$_[0]})   }
    sub _uncompress_lz4 { ${$_[1]} = Compress::LZ4::decompress(${$_[0]}) }
}

my $_CACHE = Cache::Memcached::Fast::Safe->new(
    servers            => ['127.0.0.1:11211'],
    utf8               => 1,
    serialize_methods  => [\&_message_pack, \&_message_unpack],
    ketama_points      => 150,
    hash_namespace     => 0,
    compress_threshold => 5_000,
    compress_methods   => [\&_compress_lz4, \&_uncompress_lz4],
);
sub cache { $_CACHE }

sub load_config {
    my $self = shift;
    return $self->{_config} if $self->{_config};
    open( my $fh, '<', $self->root_dir . '/../config/hosts.json') or die $!;
    local $/;
    my $json = <$fh>;
    $self->{_config} = decode_json($json);    
}

sub dbh {
    my $self = shift;
    my $config = $self->load_config;
    my $host = $config->{servers}->{database}->[0] || '127.0.0.1';
    DBI->connect_cached('dbi:mysql:isucon;host='.$host,'isuconapp','isunageruna',{
        RaiseError => 1,
        PrintError => 0,
        ShowErrorStatement => 1,
        AutoInactiveDestroy => 1,
        mysql_enable_utf8 => 1
    });
}

filter 'recent_commented_articles' => sub {
    my $app = shift;
    sub {
        my ( $self, $c )  = @_;
        $c->stash->{recent_commented_articles} = $self->dbh->selectall_arrayref(
            'SELECT id, title FROM article ORDER BY last_commented_at DESC LIMIT 10',
            { Slice => {} });
        $app->($self,$c);
    }
};

sub root {
    my ($self, $c, $template) = @_;

    my $rows = $self->dbh->selectall_arrayref(
        'SELECT id,title,body,created_at FROM article ORDER BY id DESC LIMIT 10',
        { Slice => {} });
    $c->render($template || 'index.tx', { articles => $rows });

}

get '/' => [qw/recent_commented_articles/] => \&root;

sub article {
    my ( $self, $c, $template )  = @_;
    my $article = $self->cache->get_or_set(
        'article:' . $c->args->{articleid},
        sub {
            $self->dbh->selectrow_hashref(
                'SELECT id,title,body,created_at FROM article WHERE id=?',
                {}, $c->args->{articleid}
            );
        },
    );

    my $comments = $self->cache->get_or_set(
        'comments:' . $c->args->{articleid},
        sub {
            $self->dbh->selectall_arrayref(
                'SELECT id,name,body,created_at FROM comment WHERE article=? ORDER BY id',
                { Slice => {} }, $c->args->{articleid}
            );
        }
    );
    $c->render($template || 'article.tx', { article => $article, comments => $comments });
}

get '/article/:articleid' => [qw/recent_commented_articles/] => \&article;

sub get_post {
    my ( $self, $c, $template )  = @_;
    $c->render($template || 'post.tx');
}

get '/post' => [qw/recent_commented_articles/] => \&get_post;

post '/post' => sub {
    my ( $self, $c )  = @_;
    my $sth = $self->dbh->prepare_cached('INSERT INTO article SET title = ?, body = ?');
    $sth->execute($c->req->param('title'), $c->req->param('body'));
    $c->redirect($c->req->uri_for('/'));
};

post '/comment/:articleid' => sub {
    my ( $self, $c )  = @_;

    my $sth = $self->dbh->prepare_cached('INSERT INTO comment SET article = ?, name =?, body = ?');
    $sth->execute(
        $c->args->{articleid},
        $c->req->param('name'), 
        $c->req->param('body')
    );

    $sth = $self->dbh->prepare_cached('UPDATE article SET last_commented_at = CURRENT_TIMESTAMP() WHERE id = ?');
    $sth->execute($c->args->{articleid});

    my $comment_id = $self->dbh->do('SELECT LAST_INSERT_ID()');
    my $key = 'comments:'. $c->args->{articleid};
    my $comments = $self->cache->get($key) || [];
    if (@$comments) {
        my $inserted_comment = $self->dbh->selectrow_hashref(
            'SELECT id,name,body,created_at FROM comment WHERE id=?',
            {}, $comment_id
        );
        push @$comments, $inserted_comment;
    } else {
        $comments = $self->dbh->selectall_arrayref(
            'SELECT id,name,body,created_at FROM comment WHERE article=? ORDER BY id',
            { Slice => {} }, $c->args->{articleid}
        );
    }
    $self->cache->set($key, $comments);

    $c->redirect($c->req->uri_for('/article/'.$c->args->{articleid}));
};

1;

