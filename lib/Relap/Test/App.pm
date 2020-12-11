package Relap::Test::App;

=pod
Задача: вывести веб-страницу, которая покажет на каких сайтах из топ50 по России по версии SimilarWeb используется Яндекс.Метрика, а на каких Google.Аналитика.

Ограничения:
Страница должна рендериться быстро (<1s). Скорее всего, этого не получится достичь при синхронной реализации (когда запрос к веб-странице породит множество запросов внутри воркера, а ответы сразу же группируются к выдаче), поэтому, тут от кандидата требуется подумать, как уложиться в данное требование.
Решение должно быть доступно в публичном репозитории на github/gitlab/bitbucket
Язык бэкенд части - Perl (5.26). Мы используем Mojolicious в качестве веб-фреймворка, Mojo::UserAgent в качестве юзер-агента, Mojo::DOM для парсинга страниц, Moo для ООП и MooX::Options в качестве основы для консольных скриптов. Будет здорово, если ваше решение тоже будет использовать какие-то из этих технологий (плюс, они заметно могут облегчить написание, и для них есть много готовых кукбуков, например, https://metacpan.org/pod/distribution/Mojolicious/lib/Mojolicious/Guides/Cookbook.pod#Web-scraping или https://metacpan.org/pod/release/SRI/Mojolicious-8.58/lib/Mojolicious/Guides/Cookbook.pod#Backend-web-services).
Красота верстки фронтенда не имеет особого значения (она должна быть валидной и логичной, и все).

Уточнения:
Есть большое количество аналогов similarweb (Рамблер.Топ, Alexa) - если какой-то из них представляет данные в более удобном формате/API - можно использовать их вместо similarweb.
Во время рендеринга страницы можно обращаться к внутренней Базе Данных. Что это будет - SQL, NoSQL, файл (txt, tsv, json) - не важно, выбирайте самый удобный для вас вариант.
Для упрощения, можно определять, что запросы на Яндекс.Метрику пойдут к домену mc.yandex.ru, а в Гугл.Аналитику к домену www.google-analytics.com
Нам приятно работать с кодом, соответствующим современным гайдлайнам стиля и структурирования для Perl программ (https://github.com/Perl/perl5/wiki/Defaults-for-v7). Прагмы use strict/use warnings должны быть обязательными, остальное (сигнатуры/...) - по желанию. Писать в функциональном стиле (map {} grep {} map {} … @list) тоже не стоит, тк это сильно ухудшает читабельность.
=cut

use strict;
use warnings;
use v5.26;
use utf8;

use Mojo::Base 'Mojolicious', -signatures;
use Mojo::DOM;

use Relap::Test::PageFetcher;

use constant {
	INDEX_PAGE_URL	=> 'https://www.similarweb.com/top-websites/russian-federation/',
	NUM_OF_TOP_SITES=> 50,
};

my $page_fetcher = Relap::Test::PageFetcher->new();

sub _fetch_data($do_refresh = 0) {
	
	state($cache, $cache_ctime);
	
	if($cache and ! $do_refresh) {
		return Mojo::Promise->resolve($cache, $cache_ctime);
	}
	
	my $new_ctime;

	# функции внутри then можно объявить отдельно, это немного упрощает их независимое тестирование
	# return $page_fetcher->do(...)
	# 	->then( \&_parse_similar_web_index )
	# 	->then( \&_parse_sites_index)

	return $page_fetcher->do(INDEX_PAGE_URL, $do_refresh ? 0 : undef)
		->then(sub($html, $url, $ctime) {
			die "Similarweb parsing error" if ! $html;

			# можно получить Mojo::Dom объект из tx: $tx->res->dom; и передавать его сюда сразу вместо $html
			my $dom = Mojo::DOM->new($html);
			
			# HTML5::DOM так же может
			my $table = $dom->at('.topRankingGrid-body');
			if(! $table) {
				$page_fetcher->invalid(INDEX_PAGE_URL);
				#warn $body;
				die "Similarweb parsing error";
			}
			
			$new_ctime = $ctime;
			
			my @sites;

			# есть правило, которое говорит нам, что не надо использовать $a и $b как имена переменных
			# https://perlmaven.com/dont-use-a-and-b-variables
			foreach my Mojo::DOM $a ($table->find('tr > td.topRankingGrid-cell.topWebsitesGrid-cellWebsite.showInMobile > div > a.sprite.linkout.topRankingGrid-blankLink')->each) {
				push @sites, $a->attr('href');
				last if @sites == NUM_OF_TOP_SITES;
			}
			
			if(! @sites) {
				$page_fetcher->invalid(INDEX_PAGE_URL);
				die "Similarweb parsing error";
			}

			# 50 одновременных соединений - это, пожалуй, чересчур много. В практических задачах лучше на один тред
			# так много не вешать или для начала произвести какой-то бенчмарк.
			my @promises;
			foreach my $site (@sites) {
				push @promises, $page_fetcher->do($site, $do_refresh ? 0 : undef);
			}

			# для этой задачи лучше использовать Mojo::Promise->all_settled, а не Mojo::Promise->all
			# промис all будет rejected, если хотя бы один из дочерних промисов был rejected
			# легко представить ситуацию, когда из 50 запущенных соединений одно затаймаутило и вот у нас нет
			# никаких данных, даже с учётом того, что 49 запросов завершились успешно
			#
			# UPD:
			# После того как я почитал код PageFetcher, вижу, что ты эту проблему обошел, перехватывая reject
			# в catch ))
			# но all_settled более прямой способ
			return Mojo::Promise->all(@promises);
		})
		->then(sub(@results) {
			my(@metrica, @analytics, @nothing, @unknown);
			foreach my $result (@results) {
				if($result->[0]) {

					# nothing не используется дальше. Такие ошибки и недочеты, кстати, очень легко ловить в IDEA
					my($metrica, $analytics, $nothing);
					my $dom = Mojo::DOM->new($result->[0]);
					foreach my Mojo::DOM $script ($dom->find('script')->each) {
						if($script->attr('src')) {
							$metrica = 1 if ! $metrica and $script->attr('src') =~ /^https?:\/\/mc\.yandex\.ru\//;
							# Не это надо искать
							$analytics = 1 if ! $analytics and $script->attr('src') =~ /^https?:\/\/www\.google-analytics\.com\//;
						} else {
							$metrica = 1 if ! $metrica and $script->content =~ /"https?:\/\/mc\.yandex\.ru\//;
							$analytics = 1 if ! $analytics and $script->content =~ /'https?:\/\/www\.google-analytics\.com\//;
						}
					}
					push @metrica, $result->[1] if $metrica;
					push @analytics, $result->[1] if $analytics;
					push @nothing, $result->[1] if ! $metrica and ! $analytics;
				} else {
					# я сомневаюсь, что код сюда попадет, а не в catch, если случится ошибка
					push @unknown, $result->[1];
				}
			}
			
			return $cache = {metrica => \@metrica, analytics => \@analytics, nothing => \@nothing, unknown => \@unknown},
				$cache_ctime = $new_ctime;
		})
}

use constant FRESH_DATA_FETCH_MIN_PERIOD => 60; # Запрашиваем свежие данные не чаще раза в столько секунд

sub startup ($self) {
	
	# Вообще все вводные данные для ресурсоёмкой работы известны заранее, так что можно выполнить эту работу заранее ещё до запроса
	_fetch_data()->wait;
	# А так же можно попросить добыть свежие данные, но уже не дожидаясь их готовности стартовая с имеющимися
	_fetch_data(1)->catch(sub ($err) {warn $err});
	# Запомним, когда последний раз запрашивали свежие данные, чтобы не делать это слишком часто
	state $last_refresh_time = time;
	
	$self->routes->get('/' => sub($c) {
		
		_fetch_data()
			# немного неожиданно писать catch раньше then. Вообще, лучше стараться не писать неожиданный код,
			# если обстоятельства этого не требуют
			# под неожиданным я понимаю вот что: если все примеры в документации сначала пишут then, а потом catch
			# то лучше сохранить эту конвенцию, тем более, что это похоже на классический try/catch
			# тут можно возразить, что лучше сначала написать что-то короткое и понятное, но
			->catch(sub($err) {$c->reply->exception($err)})
			->then(sub($results, $ctime) {
				$c->render(
					template=> 'index',
					groups	=> [
						{name => 'Яндекс.Метрика',	sites => $results->{metrica}},
						{name => 'Google Analytics',sites => $results->{analytics}},
						{name => 'Ничего из этого',	sites => $results->{nothing}},
						{name => 'Неизвестно =(',	sites => $results->{unknown}},
					],
					ctime	=> scalar localtime($ctime),
				);
			});
		
		$c->render_later;
		
		if(time - $last_refresh_time > FRESH_DATA_FETCH_MIN_PERIOD) {
			$last_refresh_time = time;
			_fetch_data(1)->catch(sub ($err) {warn $err});
		}
	});
}

1;
