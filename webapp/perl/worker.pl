use strict;
use warnings;
use utf8;

use FindBin;
use Redis::Fast;
use Parallel::Prefork;
use Time::HiRes qw/sleep/;
use Text::Xslate;
use Path::Tiny;

my $tx = Text::Xslate->new(
    path        => [ "$FindBin::Bin/views" ],
    input_layer => ':utf8',
    module      => ['Text::Xslate::Bridge::TT2Like','Number::Format' => [':subs']],
);

sub dbh {
    DBI->connect_cached('dbi:mysql:isucon;host=127.0.0.1','isuconapp','isunageruna',{
        RaiseError => 1,
        PrintError => 0,
        ShowErrorStatement => 1,
        AutoInactiveDestroy => 1,
        mysql_enable_utf8 => 1
    });
}

my %FUNC = (
    post_article => sub {
        my $args = shift;
        my $dbh = dbh();
        my $dir = path("$FindBin::Bin/public/articles/$args->{id}");
        $dir->mkpath;

        my $article = $dbh->selectrow_hashref(
            'SELECT id,title,body,created_at FROM article WHERE id=?',
            {}, $args->{id}
        );
        my $article_body = $tx->render('article_body.tx', { article => $article });
        $dir->child('body.html')->spew_utf8($article_body);

        my $article_comments = $tx->render('article_comment.tx', { article => $article, comments => [] });
        $dir->child('comments.html')->spew_utf8($article_comments);
    },
    post_comment => sub {
        my $args = shift;
        my $dbh = dbh();
        my $dir = path("$FindBin::Bin/public/articles/$args->{id}");
        $dir->mkpath;

        # ...
    },
);

my $pm = Parallel::Prefork->new({
    max_workers  => 10,
    trap_signals => {
        TERM => 'TERM',
        HUP  => 'TERM',
    }
});

while ($pm->signal_received ne 'TERM') {
    $pm->start(sub {
        my $redis = Redis::Fast->new(
            server    => '127.0.0.1:6379',
            reconnect => 1,
        );
        while (1) {
            my $task = $redis->rpop('isucon:queue');
            unless ($task) {
                sleep 0.1;
                next;
            }

            my ($func, $args) = @$task{qw/func args/};
            $FUNC{$func}->($args);
        }
    });
}

$pm->wait_all_children();


