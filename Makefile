php-cs-fixer-test-docker:
	# Version must match the one in the GitHub workflow and pre-commit
	docker run --rm -w=/app -v ${PWD}:/app ghcr.io/php-cs-fixer/php-cs-fixer:3.69-php8.1 check --config=.php_cs.dist.php --allow-risky=yes --diff

php-cs-fixer-apply-docker:
	# Version must match the one in the GitHub workflow and pre-commit
	docker run --rm -it -w=/app -v ${PWD}:/app ghcr.io/php-cs-fixer/php-cs-fixer:3.69-php8.1 fix --config=.php_cs.dist.php --allow-risky=yes
