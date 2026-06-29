bash enable_RO.sh
wrmsr 0xc8b 0xc000

RUN_LABEL=ro_on_c000 bash sweep_intel_pcm_t16.sh
RUN_LABEL=ro_on_c000 bash sweep_intel_pcm_t33.sh

bash disable_RO.sh
wrmsr 0xc8b 0xc000

RUN_LABEL=ro_off_c000 bash sweep_intel_pcm_t16.sh
RUN_LABEL=ro_off_c000 bash sweep_intel_pcm_t33.sh

bash enable_RO.sh
wrmsr 0xc8b 0xff00

RUN_LABEL=ro_on_ff00 bash sweep_intel_pcm_t16.sh
RUN_LABEL=ro_on_ff00 bash sweep_intel_pcm_t33.sh

bash disable_RO.sh
wrmsr 0xc8b 0xff00

RUN_LABEL=ro_off_ff00 bash sweep_intel_pcm_t16.sh
RUN_LABEL=ro_off_ff00 bash sweep_intel_pcm_t33.sh
