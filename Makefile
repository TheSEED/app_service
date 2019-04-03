TOP_DIR = ../..
include $(TOP_DIR)/tools/Makefile.common

TARGET ?= /kb/deployment
DEPLOY_TARGET ?= $(TARGET)
DEPLOY_RUNTIME ?= /kb/runtime
SERVER_SPEC = AppService.spec

SERVICE_MODULE = lib/Bio/KBase/AppService/Service.pm

SERVICE = app_service
SERVICE_PORT = 7124

SERVICE_URL = http://p3.theseed.org/services/$(SERVICE)

SERVICE_NAME = AppService
SERVICE_NAME_PY = $(SERVICE_NAME)

SERVICE_PSGI_FILE = $(SERVICE_NAME).psgi

SRC_SERVICE_PERL = $(wildcard service-scripts/*.pl)
BIN_SERVICE_PERL = $(addprefix $(BIN_DIR)/,$(basename $(notdir $(SRC_SERVICE_PERL))))
DEPLOY_SERVICE_PERL = $(addprefix $(SERVICE_DIR)/bin/,$(basename $(notdir $(SRC_SERVICE_PERL))))

STARMAN_WORKERS = 5

#DATA_API_URL = https://www.patricbrc.org/api
DATA_API_URL = https://p3.theseed.org/services/data_api
GITHUB_ISSUE_REPO_OWNER = olsonanl
GITHUB_ISSUE_REPO_NAME = app_service

SEEDTK = /disks/patric-common/seedtk-2018-0820

REFERENCE_DATA_DIR = /tmp

MASH_REFERENCE_SKETCH = /vol/patric3/production/data/trees/listOfRepRefGenomeFnaFiles.txt.msh 

ifdef TEMPDIR
TPAGE_TEMPDIR = --define kb_tempdir=$(TEMPDIR)
endif

ifdef DEPLOYMENT_VAR_DIR
SERVICE_LOGDIR = $(DEPLOYMENT_VAR_DIR)/services/$(SERVICE)
TPAGE_SERVICE_LOGDIR = --define kb_service_log_dir=$(SERVICE_LOGDIR)
endif

TPAGE_BUILD_ARGS =  \
	--define kb_top=$(TARGET) \
	--define kb_runtime=$(DEPLOY_RUNTIME)

TPAGE_DEPLOY_ARGS =  \
	--define kb_top=$(DEPLOY_TARGET) \
	--define kb_runtime=$(DEPLOY_RUNTIME)

TPAGE_ARGS = \
	--define kb_service_name=$(SERVICE) \
	--define kb_service_port=$(SERVICE_PORT) \
	--define kb_psgi=$(SERVICE_PSGI_FILE) \
	--define kb_starman_workers=$(STARMAN_WORKERS) \
	--define data_api_url=$(DATA_API_URL) \
	--define db_host=$(DB_HOST) \
	--define db_user=$(DB_USER) \
	--define db_pass=$(DB_PASS) \
	--define db_name=$(DB_NAME) \
	--define seedtk=$(SEEDTK) \
	--define github_issue_repo_owner=$(GITHUB_ISSUE_REPO_OWNER) \
	--define github_issue_repo_name=$(GITHUB_ISSUE_REPO_NAME) \
	--define github_issue_token=$(GITHUB_ISSUE_TOKEN) \
	--define reference_data_dir=$(REFERENCE_DATA_DIR) \
	--define binning_genome_annotation_clientgroup=$(BINNING_GENOME_ANNOTATION_CLIENTGROUP) \
	--define binning_spades_threads=$(BINNING_SPADES_THREADS) \
	--define binning_spades_ram=$(BINNING_SPADES_RAM) \
	--define bebop_binning_key=$(BEBOP_BINNING_KEY) \
	--define bebop_binning_user=$(BEBOP_BINNING_USER) \
	--define mash_reference_sketch=$(MASH_REFERENCE_SKETCH) \
	$(TPAGE_SERVICE_LOGDIR) \
	$(TPAGE_TEMPDIR)

TESTS = $(wildcard t/client-tests/*.t)

all: build-libs bin compile-typespec service build-dancer-config 

build-libs:
	$(TPAGE) $(TPAGE_BUILD_ARGS) $(TPAGE_ARGS) AppConfig.pm.tt > lib/Bio/KBase/AppService/AppConfig.pm

test:
	# run each test
	echo "RUNTIME=$(DEPLOY_RUNTIME)\n"
	for t in $(TESTS) ; do \
		if [ -f $$t ] ; then \
			$(DEPLOY_RUNTIME)/bin/perl $$t ; \
			if [ $$? -ne 0 ] ; then \
				exit 1 ; \
			fi \
		fi \
	done

service: $(SERVICE_MODULE)

compile-typespec: Makefile
	mkdir -p lib/biokbase/$(SERVICE_NAME_PY)
	touch lib/biokbase/__init__.py #do not include code in biokbase/__init__.py
	touch lib/biokbase/$(SERVICE_NAME_PY)/__init__.py 
	mkdir -p lib/javascript/$(SERVICE_NAME)
	compile_typespec \
		--patric \
		--impl Bio::KBase::$(SERVICE_NAME)::%sImpl \
		--service Bio::KBase::$(SERVICE_NAME)::Service \
		--client Bio::KBase::$(SERVICE_NAME)::Client \
		--py biokbase/$(SERVICE_NAME_PY)/client \
		--js javascript/$(SERVICE_NAME)/Client \
		--url $(SERVICE_URL) \
		$(SERVER_SPEC) lib
	-rm -f lib/$(SERVER_MODULE)Server.py
	-rm -f lib/$(SERVER_MODULE)Impl.py
	-rm -f lib/CDMI_EntityAPIImpl.py

bin: $(BIN_PERL) $(BIN_SERVICE_PERL) $(BIN_SH)

#
# Manually run this to update the AweEvents module.
#
log-events: 
	perl make-log-events-data.pl > lib/Bio/KBase/AppService/AweEvents.pm

deploy: deploy-client deploy-service
deploy-all: deploy-client deploy-service
deploy-client: compile-typespec build-libs deploy-docs deploy-libs deploy-scripts 

deploy-service: deploy-dir deploy-monit deploy-libs deploy-service-scripts deploy-dancer-config
	for script in start_service stop_service postinstall; do \
		$(TPAGE) $(TPAGE_DEPLOY_ARGS) $(TPAGE_ARGS) service/$$script.tt > $(TARGET)/services/$(SERVICE)/$$script ; \
		chmod +x $(TARGET)/services/$(SERVICE)/$$script ; \
	done
	mkdir -p $(TARGET)/postinstall
	rm -f $(TARGET)/postinstall/$(SERVICE)
	ln -s ../services/$(SERVICE)/postinstall $(TARGET)/postinstall/$(SERVICE)
	rsync -arv app_specs $(TARGET)/services/$(SERVICE)/.

deploy-dancer-config:
	$(TPAGE) --define deployment_flag=1 $(TPAGE_DEPLOY_ARGS) $(TPAGE_ARGS) dancer_config.yml.tt > $(TARGET)/services/$(SERVICE)/config.yml

build-dancer-config:
	$(TPAGE) $(TPAGE_BUILD_ARGS) $(TPAGE_ARGS) dancer_config.yml.tt > lib/Bio/KBase/AppService/config.yml

deploy-service-scripts:
	export KB_TOP=$(TARGET); \
	export KB_RUNTIME=$(DEPLOY_RUNTIME); \
	export KB_PERL_PATH=$(TARGET)/lib ; \
	export PATH_PREFIX=$(TARGET)/services/$(SERVICE)/bin:$(TARGET)/services/cdmi_api/bin; \
	for src in $(SRC_SERVICE_PERL) ; do \
	        basefile=`basename $$src`; \
	        base=`basename $$src .pl`; \
	        echo install $$src $$base ; \
	        cp $$src $(TARGET)/plbin ; \
	        $(WRAP_PERL_SCRIPT) "$(TARGET)/plbin/$$basefile" $(TARGET)/services/$(SERVICE)/bin/$$base ; \
	done

deploy-monit:
	$(TPAGE) $(TPAGE_DEPLOY_ARGS) $(TPAGE_ARGS) service/process.$(SERVICE).tt > $(TARGET)/services/$(SERVICE)/process.$(SERVICE)

deploy-docs:
	-mkdir doc
	-mkdir $(SERVICE_DIR)
	-mkdir $(SERVICE_DIR)/webroot
	mkdir -p doc
	$(DEPLOY_RUNTIME)/bin/pod2html -t "App Service API" lib/Bio/KBase/AppService/AppServiceImpl.pm > doc/app_service_impl.html
	cp doc/*html $(SERVICE_DIR)/webroot/.

deploy-dir:
	if [ ! -d $(SERVICE_DIR) ] ; then mkdir $(SERVICE_DIR) ; fi
	if [ ! -d $(SERVICE_DIR)/webroot ] ; then mkdir $(SERVICE_DIR)/webroot ; fi
	if [ ! -d $(SERVICE_DIR)/bin ] ; then mkdir $(SERVICE_DIR)/bin ; fi

$(BIN_DIR)/%: service-scripts/%.pl $(TOP_DIR)/user-env.sh
	$(WRAP_PERL_SCRIPT) '$$KB_TOP/modules/$(CURRENT_DIR)/$<' $@

$(BIN_DIR)/%: service-scripts/%.py $(TOP_DIR)/user-env.sh
	$(WRAP_PYTHON_SCRIPT) '$$KB_TOP/modules/$(CURRENT_DIR)/$<' $@

include $(TOP_DIR)/tools/Makefile.common.rules
