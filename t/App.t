package main;

use 5.026;
use strict;
use warnings;
use utf8;

use Test::Mojo;
use Test::Spec;
use Time::HiRes qw(time);
use Data::Dumper;

describe 'Relap::Test::App' => sub {
	it 'Works as described in requirements' => sub {
		my $mojo = Test::Mojo->new('Relap::Test::App');
		ok(defined $mojo, 'App can be initialized via Test::Mojo');
		
		for (1 .. 100) {
			my $t = time;
			my $r = $mojo->get_ok('/');
			$t -= time;
			ok($t < 1, "App should respond to each request in less than 1 second");
			
			$r->status_is(200);
			
			ok(scalar $r->tx->res->dom->find('li')->each >= 50, "Response is about 50 sites");
			
			my %lists;
			foreach my $li ($r->tx->res->dom->find('li')->each) {
				push @{ $lists{ $li->parent->previous->content } }, $li->content;
			}
			ok(scalar keys(%lists) >= 3, "Sites splitted by a 3 or more groups");
			
			ok((! grep {! @$_} values %lists), "Each group is not empty");
		}
	};
};

runtests unless caller;
