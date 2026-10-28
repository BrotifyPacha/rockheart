.PHONY: deps deploy clients check-target lint test

deps:
	ansible-galaxy collection install -r requirements.yml

deploy:
	ansible-playbook site.yml

# Перегенерировать ссылки и QR-коды без изменения сервера
clients:
	ansible-playbook site.yml --tags clients

check-target:
	ansible-playbook site.yml --tags check_target

lint:
	ansible-lint
	ansible-playbook site.yml --syntax-check -i inventory/hosts.example.yml

# Полный прогон плейбука в контейнере и проверка туннеля клиентом
test:
	./tests/e2e/run.sh
