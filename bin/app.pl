#!/usr/bin/perl

use Mojo::Base -strict;
use lib qw(lib);
use Mojolicious::Commands;

Mojolicious::Commands->start_app('Relap::Test::App');
