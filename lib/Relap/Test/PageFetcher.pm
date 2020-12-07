package Relap::Test::PageFetcher;

use strict;
use warnings;
use v5.26;
use utf8;
use feature qw(signatures state);
use MIME::Base64 qw(encode_base64url);

use Mojo::Promise;
use Mojo::URL;

use Moo;
no warnings "experimental::signatures";

has _pages => (
	is		=> 'ro',
	default	=> sub {{}},
);

has _page_ctime => (
	is		=> 'ro',
	default	=> sub {{}},
);

has _cache_dir => (
	is		=> 'ro',
	default	=> sub {Mojo::Home->new->detect('Relap::Test')->child('ext_pages_cache')->make_path({mode => 0700})},
);

=pod

Fetch specified url, using file cache and in memory cache.

Params: #TODO:
Returns a promise with ['page html code' if successful, 'page url', $page_ctime if succesful] as result.
=cut
sub do($self, $url, $max_age = undef) {
	
	if(exists $self->_pages->{$url} and (! defined $max_age or time - $self->_page_ctime->{$url} < $max_age)) {
		return Mojo::Promise->new->resolve($self->_pages->{$url}, $url, $self->_page_ctime->{$url});
	}
	
	my $file = $self->_cache_dir->child(encode_base64url($url));
	my $stat = $file->stat();
	
	if($stat and (! defined $max_age or time - $stat->mtime < $max_age)) {
		my $handle = $file->open('<');
		$self->_pages->{$url} = join('', <$handle>);
		$self->_page_ctime->{$url} = $stat->mtime;
		
		return Mojo::Promise->new->resolve($self->_pages->{$url}, $url, $stat->mtime);
	} else {
		state $ua = Mojo::UserAgent->new();
		$ua->transactor->name('Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.116 Safari/537.36');
		$ua->max_redirects(5);
		my $promise = Mojo::Promise->new();
		$ua->get_p($url)
			->then(sub($tx) {
				if($tx->result->code != 200) {
					$promise->resolve(undef, $url);
				} else {
					my $page = $tx->result->body;
					$self->_pages->{$url} = $page;
					$self->_page_ctime->{$url} = time;
					$promise->resolve($page, $url, $self->_page_ctime->{$url});
					my $handle = $file->open('>');
					print $handle $page;
				}
			})
			->catch(sub($err) {
				warn "Fetch url '$url' failed: $err";
				$promise->resolve(undef, $url, undef);
			});
		return $promise;
	}
}

sub invalid($self, $url) {
	delete $self->_pages->{$url};
	delete $self->_page_ctime->{$url};
	
	$self->_cache_dir->child(encode_base64url($url))->remove();
}

1;
