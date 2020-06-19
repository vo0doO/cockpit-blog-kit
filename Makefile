# извлечь имя из package.json
PACKAGE_NAME := $(shell awk '/"name":/ {gsub(/[",]/, "", $$2); print $$2}' package.json)
VERSION := $(shell T=$$(git describe 2>/dev/null) || T=1; echo $$T | tr '-' '.')
ifeq ($(TEST_OS),)
TEST_OS = centos-7
endif
export TEST_OS
TARFILE=cockpit-$(PACKAGE_NAME)-$(VERSION).tar.gz
RPMFILE=$(shell rpmspec -D"VERSION $(VERSION)" -q cockpit-blog-kit.spec.in).rpm
VM_IMAGE=$(CURDIR)/test/images/$(TEST_OS)
# файл штампа, чтобы проверить, запускалась ли npm установка
NODE_MODULES_TEST=package-lock.json
# один пример файла в dist / from webpack, чтобы проверить, что он уже запущен
WEBPACK_TEST=dist/index.html

all: $(WEBPACK_TEST)

#
# i18n
#

LINGUAS=$(basename $(notdir $(wildcard po/*.po)))

po/POTFILES.js.in:
	mkdir -p $(dir $@)
	find src/ -name '*.js' -o -name '*.jsx' > $@

po/$(PACKAGE_NAME).js.pot: po/POTFILES.js.in
	xgettext --default-domain=cockpit --output=$@ --language=C --keyword= \
		--keyword=_:1,1t --keyword=_:1c,2,1t --keyword=C_:1c,2 \
		--keyword=N_ --keyword=NC_:1c,2 \
		--keyword=gettext:1,1t --keyword=gettext:1c,2,2t \
		--keyword=ngettext:1,2,3t --keyword=ngettext:1c,2,3,4t \
		--keyword=gettextCatalog.getString:1,3c --keyword=gettextCatalog.getPlural:2,3,4c \
		--from-code=UTF-8 --files-from=$^

po/POTFILES.html.in:
	mkdir -p $(dir $@)
	find src -name '*.html' > $@

po/$(PACKAGE_NAME).html.pot: po/POTFILES.html.in
	po/html2po -f $^ -o $@

po/$(PACKAGE_NAME).manifest.pot:
	po/manifest2po src/manifest.json -o $@

po/$(PACKAGE_NAME).pot: po/$(PACKAGE_NAME).html.pot po/$(PACKAGE_NAME).js.pot po/$(PACKAGE_NAME).manifest.pot
	msgcat --sort-output --output-file=$@ $^

# Обновить переводы по текущему шаблону заказа на поставку
update-po: po/$(PACKAGE_NAME).pot
	for lang in $(LINGUAS); do \
		msgmerge --output-file=po/$$lang.po po/$$lang.po $<; \
	done

dist/po.%.js: po/%.po $(NODE_MODULES_TEST)
	mkdir -p $(dir $@)
	po/po2json -m po/po.empty.js -o $@.js.tmp $<
	mv $@.js.tmp $@

#
# Build/Install/dist
#

%.spec: %.spec.in
	sed -e 's/%{VERSION}/$(VERSION)/g' $< > $@

$(WEBPACK_TEST): $(NODE_MODULES_TEST) $(shell find src/ -type f) package.json webpack.config.js $(patsubst %,dist/po.%.js,$(LINGUAS))
	NODE_ENV=$(NODE_ENV) npm run build

watch:
	NODE_ENV=$(NODE_ENV) npm run watch

clean:
	rm -rf dist/
	[ ! -e cockpit-$(PACKAGE_NAME).spec.in ] || rm -f cockpit-$(PACKAGE_NAME).spec

install: $(WEBPACK_TEST)
	mkdir -p $(DESTDIR)/usr/share/cockpit/$(PACKAGE_NAME)
	cp -r dist/* $(DESTDIR)/usr/share/cockpit/$(PACKAGE_NAME)
	mkdir -p $(DESTDIR)/usr/share/metainfo/
	cp org.cockpit-project.$(PACKAGE_NAME).metainfo.xml $(DESTDIR)/usr/share/metainfo/

# это требует встроенного дерева исходных кодов и избавляет от необходимости устанавливать что-либо общесистемное
devel-install: $(WEBPACK_TEST)
	mkdir -p ~/.local/share/cockpit
	ln -s `pwd`/dist ~/.local/share/cockpit/$(PACKAGE_NAME)

dist-gzip: $(TARFILE)

# при сборке дистрибутива дистрибутива вызывайте webpack с «производственной» средой
# мы не отправляем node_modules по соображениям лицензии и компактности; мы отправляем
# предварительно созданный dist / (так что в этом нет необходимости) и корабль packge-lock.json (чтобы
# node_modules / могут быть восстановлены при необходимости)
$(TARFILE): NODE_ENV=production
$(TARFILE): $(WEBPACK_TEST) cockpit-$(PACKAGE_NAME).spec
	if type appstream-util >/dev/null 2>&1; then appstream-util validate-relax --nonet *.metainfo.xml; fi
	mv node_modules node_modules.release
	touch -r package.json $(NODE_MODULES_TEST)
	touch dist/*
	tar czf cockpit-$(PACKAGE_NAME)-$(VERSION).tar.gz --transform 's,^,cockpit-$(PACKAGE_NAME)/,' \
		--exclude cockpit-$(PACKAGE_NAME).spec.in \
		$$(git ls-files) package-lock.json cockpit-$(PACKAGE_NAME).spec dist/
	mv node_modules.release node_modules

srpm: $(TARFILE) cockpit-$(PACKAGE_NAME).spec
	rpmbuild -bs \
	  --define "_sourcedir `pwd`" \
	  --define "_srcrpmdir `pwd`" \
	  cockpit-$(PACKAGE_NAME).spec

rpm: $(RPMFILE)

$(RPMFILE): $(TARFILE) cockpit-$(PACKAGE_NAME).spec
	mkdir -p "`pwd`/output"
	mkdir -p "`pwd`/rpmbuild"
	rpmbuild -bb \
	  --define "_sourcedir `pwd`" \
	  --define "_specdir `pwd`" \
	  --define "_builddir `pwd`/rpmbuild" \
	  --define "_srcrpmdir `pwd`" \
	  --define "_rpmdir `pwd`/output" \
	  --define "_buildrootdir `pwd`/build" \
	  cockpit-$(PACKAGE_NAME).spec
	find `pwd`/output -name '*.rpm' -printf '%f\n' -exec mv {} . \;
	rm -r "`pwd`/rpmbuild"
	rm -r "`pwd`/output" "`pwd`/build"
	# санитарная проверка
	test -e "$(RPMFILE)"

# собрать виртуальную машину с установленным локально установленным RPM
$(VM_IMAGE): $(RPMFILE) bots
	rm -f $(VM_IMAGE) $(VM_IMAGE).qcow2
	bots/image-customize -v -i cockpit-ws -i `pwd`/$(RPMFILE) -s $(CURDIR)/test/vm.install $(TEST_OS)

# удобство цели для вышеупомянутого
vm: $(VM_IMAGE)
	echo $(VM_IMAGE)

# запустить тесты интеграции браузера; пропустить проверку на отказ SELinux
# это запустит все тесты / check- * и отформатирует их как TAP
check: $(NODE_MODULES_TEST) $(VM_IMAGE) test/common
	TEST_AUDIT_NO_SELINUX=1 test/common/run-tests

# проверить ботов Cockpit для стандартных тестовых образов виртуальных машин и API для их запуска
# должен быть от мастера, так как только тот имеет текущие и существующие изображения; но API testvm.py стабильный
# поддержка тестирования CI против смены ботов
bots:
	git clone --quiet --reference-if-able $${XDG_CACHE_HOME:-$$HOME/.cache}/cockpit-project/bots https://github.com/cockpit-project/bots.git
	if [ -n "$$COCKPIT_BOTS_REF" ]; then git -C bots fetch --quiet --depth=1 origin "$$COCKPIT_BOTS_REF"; git -C bots checkout --quiet FETCH_HEAD; fi
	@echo "checked out bots/ ref $$(git -C bots rev-parse HEAD)"

# проверка API-интерфейса Cockpit; это не дает гарантии стабильности API, поэтому проверьте стабильный тег
# при запуске нового проекта используйте последнюю версию и время от времени обновляйте ее
test/common:
	git fetch --depth=1 https://github.com/cockpit-project/cockpit.git 220
	git checkout --force FETCH_HEAD -- test/common
	git reset test/common

$(NODE_MODULES_TEST): package.json
	# если он уже существует, npm install не будет обновлять его; заставить это так, чтобы мы всегда получали актуальные пакеты
	rm -f package-lock.json
	# unset NODE_ENV, иначе пропускает devDependencies
	env -u NODE_ENV npm install
	env -u NODE_ENV npm prune

.PHONY: all clean install devel-install dist-gzip srpm rpm check vm update-po
