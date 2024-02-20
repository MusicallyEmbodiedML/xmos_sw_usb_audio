#include <platform.h>
#include <xs1.h>
#include <print.h>
#include <stdlib.h>
#include <string.h>
#include "i2s.h"
#include "src.h"
#include "xua.h"
#include "asynchronous_fifo.h"
#include "asrc_timestamp_interpolation.h"
#include <xscope.h>

/* TODO
    - Seperate recording and playback SRC related defines
*/

#ifndef USE_ASRC
#define USE_ASRC (0)
#endif

#ifndef EXTRA_I2S_CHAN_COUNT_IN
#define EXTRA_I2S_CHAN_COUNT_IN  (2)
#endif

#ifndef EXTRA_I2S_CHAN_INDEX_IN
#define EXTRA_I2S_CHAN_INDEX_IN  (0)
#endif

#ifndef EXTRA_I2S_CHAN_COUNT_OUT
#define EXTRA_I2S_CHAN_COUNT_OUT (2)
#endif

#ifndef EXTRA_I2S_CHAN_INDEX_OUT
#define EXTRA_I2S_CHAN_INDEX_OUT (0)
#endif

#define DATA_BITS                (32)
#define SAMPLE_FREQUENCY         (48000)

void exit(int);

unsafe chanend uc_i2s;

/* Note, re-using I2S data lines on MC audio board for LR and Bit clocks */
#if (EXTRA_I2S_CHAN_COUNT_OUT > 0)
on tile[1]: out buffered port:32 p_i2s_dout[1] = {PORT_I2S_DAC1};
#else
#define p_i2s_dout null
#endif

#if (EXTRA_I2S_CHAN_COUNT_IN > 0)
on tile[1]: in buffered port:32 p_i2s_din[1] =   {PORT_SPDIF_OUT};
#else
#define p_i2s_din null
#endif

on tile[1]: in port p_i2s_bclk =                 PORT_I2S_DAC2;
on tile[1]: in buffered port:32 p_i2s_lrclk =    PORT_I2S_DAC3;
on tile[1]: in port p_off_bclk =                 XS1_PORT_16A;
on tile[1]: clock clk_bclk =                     XS1_CLKBLK_1;

extern in port p_mclk_in;

/* TODO all these defines are shared between playback and record streams - this should be fixed */

#define     SRC_N_CHANNELS                (2)   // Total number of audio channels to be processed by SRC (minimum 1)
#define     SRC_N_INSTANCES               (2)   // Number of instances (each usually run a logical core) used to process audio (minimum 1)
#define     SRC_CHANNELS_PER_INSTANCE     (SRC_N_CHANNELS/SRC_N_INSTANCES) // Calculated number of audio channels processed by each core
#define     SRC_N_IN_SAMPLES              (4)   // Number of samples per channel in each block passed into SRC each call
                                                // Must be a power of 2 and minimum value is 4 (due to two /2 decimation stages)
#define     SRC_N_OUT_IN_RATIO_MAX        (5)   // Max ratio between samples out:in per processing step (44.1->192 is worst case)
#define     SRC_DITHER_SETTING            (0)   // Enables or disables quantisation of output with dithering to 24b
#define     SRC_MAX_NUM_SAMPS_OUT         (SRC_N_OUT_IN_RATIO_MAX * SRC_N_IN_SAMPLES)
#define     SRC_OUT_BUFF_SIZE             (SRC_CHANNELS_PER_INSTANCE * SRC_MAX_NUM_SAMPS_OUT) // Size of output buffer for SRC for each instance
#define     SRC_OUT_FIFO_SIZE             (SRC_N_CHANNELS * SRC_MAX_NUM_SAMPS_OUT * 4)        // Size of output FIFO for SRC

/* Stuff that must be defined for lib_src */
#define SSRC_N_IN_SAMPLES                 (SRC_N_IN_SAMPLES) /* Used by SRC_STACK_LENGTH_MULT in src_mrhf_ssrc.h */
#define ASRC_N_IN_SAMPLES                 (SRC_N_IN_SAMPLES) /* Used by SRC_STACK_LENGTH_MULT in src_mrhf_asrc.h */

#define SSRC_N_CHANNELS                   (SRC_CHANNELS_PER_INSTANCE) /* Used by SRC_STACK_LENGTH_MULT in src_mrhf_ssrc.h */
#define ASRC_N_CHANNELS                   (SRC_CHANNELS_PER_INSTANCE) /* Used by SRC_STACK_LENGTH_MULT in src_mrhf_asrc.h */

/* Current rate of USB input/output */
int g_usbSamFreq = DEFAULT_FREQ;

unsafe
{
    int * unsafe g_usbSamFreqPtr = &g_usbSamFreq;
}

void UserBufferManagementInit(unsigned samFreq)
{
    /* Check for sample-rate change */
    if(g_usbSamFreq != samFreq)
    {
        g_usbSamFreq = samFreq;

        unsafe
        {
            outuchar((chanend) uc_i2s, 1);
            outuint((chanend) uc_i2s, g_usbSamFreq);
            outct((chanend) uc_i2s, XS1_CT_END);

            /* Wait for handshake */
            chkct((chanend) uc_i2s, XS1_CT_END);
        }
    }
}

#pragma unsafe arrays
void UserBufferManagement(unsigned sampsFromUsbToAudio[], unsigned sampsFromAudioToUsb[])
{
    unsafe
    {
        outuchar((chanend) uc_i2s, 0);
#pragma loop unroll
        for(size_t i = 0; i < EXTRA_I2S_CHAN_COUNT_OUT; i++)
        {
            outuint((chanend)uc_i2s, sampsFromUsbToAudio[i + EXTRA_I2S_CHAN_INDEX_OUT]);
        }
        outct((chanend)uc_i2s, XS1_CT_END);

#pragma loop unroll
        for(size_t i = 0; i< EXTRA_I2S_CHAN_COUNT_IN; i++)
        {
            sampsFromAudioToUsb[i + EXTRA_I2S_CHAN_INDEX_IN] = inuint((chanend) uc_i2s);
        }
        chkct((chanend)uc_i2s, XS1_CT_END);
    }
}

#ifndef LOG_CONTROLLER_REC
#define LOG_CONTROLLER_REC (0)
#endif

#ifndef LOG_CONTROLLER_PLAY
#define LOG_CONTROLLER_PLAY (0)
#endif

#define CONT_LOG_DELAY     (0)
#define CONT_LOG_SIZE      (18000)
#define CONT_LOG_SUBSAMPLE (128)

#if LOG_CONTROLLER_REC
uint64_t r_r[CONT_LOG_SIZE];
int logCounterRec = 0;
int logCounterSubRec = 0;
#endif

#if LOG_CONTROLLER_PLAY
uint64_t r_p[CONT_LOG_SIZE];
int logCounterPlay = 0;
int logCounterSubPlay = 0;
#endif


[[distributable]]
void i2s_data(server i2s_frame_callback_if i_i2s,
    streaming chanend c_src_rec[SRC_N_INSTANCES],
    asynchronous_fifo_t * unsafe async_fifo_state_play,
    asynchronous_fifo_t * unsafe async_fifo_state_rec)
{
    int sampleIdx_rec = 0;
    int samFreq;
    unsafe
    {
        samFreq = *g_usbSamFreqPtr;
    }
    int newSamFreq = samFreq;

    float floatRatio_rec = (float) SAMPLE_FREQUENCY/(float)samFreq;
    uint64_t fsRatio_rec = (uint64_t) (floatRatio_rec * (1LL << 60));
    int idealFsRatio_rec = (fsRatio_rec + (1<<31)) >> 32;

    src_task_t srcTask_rec;
    srcTask_rec.xscopeUsed = 0;
    srcTask_rec.fsRatio = fsRatio_rec;
    srcTask_rec.idealFsRatio = idealFsRatio_rec;

    int srcInputBuff_rec[SRC_N_INSTANCES][SRC_N_IN_SAMPLES][SRC_CHANNELS_PER_INSTANCE];
#if LOG_CONTROLLER_REC
    int logCounterDelay = 0;
    int logCounterGo = 0;
#endif
    int32_t now;
    timer t;

    while(1)
    {
        select
        {
            case i_i2s.init(i2s_config_t &?i2s_config, tdm_config_t &?tdm_config):
                i2s_config.mode = I2S_MODE_I2S;

                floatRatio_rec = (float) SAMPLE_FREQUENCY/(float)samFreq;
                fsRatio_rec = (uint64_t) (floatRatio_rec * (1LL << 60));
                idealFsRatio_rec = (fsRatio_rec + (1<<31)) >> 32;

                srcTask_rec.xscopeUsed = 0;
                srcTask_rec.fsRatio = fsRatio_rec;
                srcTask_rec.idealFsRatio = idealFsRatio_rec;

                asynchronous_fifo_reset_producer(async_fifo_state_rec);
                asynchronous_fifo_init_PID_fs_codes(async_fifo_state_rec, sr_to_fscode(SAMPLE_FREQUENCY), sr_to_fscode(samFreq));

                src_change_worker_freqs(c_src_rec, SRC_N_INSTANCES, 48000, samFreq);
                break;

            /* Inform the I2S slave whether it should restart or exit */
            case i_i2s.restart_check() -> i2s_restart_t restart:

                /* Check for SR Change */
                unsafe
                {
                    newSamFreq = *g_usbSamFreqPtr;
                }
                if(samFreq != newSamFreq)
                {
                    restart = I2S_RESTART;
                    samFreq = newSamFreq;
                }
                else
                    restart = I2S_NO_RESTART;
                break;

            case i_i2s.receive(size_t num_in, int32_t samples[num_in]):

                t :> now;

#if (EXTRA_I2S_CHAN_COUNT_IN > 0)

                for(size_t i = 0; i < EXTRA_I2S_CHAN_COUNT_IN; i++)
                {
                    srcInputBuff_rec[i/SRC_CHANNELS_PER_INSTANCE][sampleIdx_rec][i % SRC_CHANNELS_PER_INSTANCE] = samples[i];
                }

                /* Add to recording path ASRC input buffer */
                sampleIdx_rec++;

                if(sampleIdx_rec == SRC_N_IN_SAMPLES)
                {
                    sampleIdx_rec = 0;

#if LOG_CONTROLLER_REC
                        logCounterDelay ++;

                        if(logCounterDelay > CONT_LOG_DELAY)
                            logCounterGo = 1;

                        if(logCounterGo)
                            logCounterSubRec++;


                        if(logCounterSubRec == CONT_LOG_SUBSAMPLE)
                        unsafe{
                            logCounterSubRec = 0;
                            r_r[logCounterRec] = fsRatio_rec;
                            ns_r[logCounterRec] = nsamps;

                            logCounterRec++;

                            if(logCounterRec >= CONT_LOG_SIZE)
                            {
                                for(int i = 0; i < CONT_LOG_SIZE; i++)
                                {
                                    float ratio = (float) r_r[i] / (float) (1LL<<60);
                                    printf("%d %f\n", ns_r[i], ratio);
                                }
                                exit(1);
                            }
                        }
#endif
                    /* Trigger_src for record path */
                    src_trigger(c_src_rec, srcInputBuff_rec, async_fifo_state_rec, now, &srcTask_rec);
                }
#endif
                break;

            case i_i2s.send(size_t num_out, int32_t samples[num_out]):

#if (EXTRA_I2S_CHAN_COUNT_OUT > 0)
                int32_t playSamples[EXTRA_I2S_CHAN_COUNT_OUT];

                asynchronous_fifo_consumer_get(async_fifo_state_play, playSamples, now);

                for(int i = 0; i < num_out; i++)
                {
                    samples[i] = playSamples[i];
                }
#endif
                break;
        }
    }
}

#define FIFO_LENGTH (100)
int64_t array[ASYNCHRONOUS_FIFO_INT64_ELEMENTS(FIFO_LENGTH, 2)];
int64_t array_rec[ASYNCHRONOUS_FIFO_INT64_ELEMENTS(FIFO_LENGTH, 2)];

#pragma unsafe arrays
int src_manager(chanend c_usb,
    streaming chanend c_src_play[SRC_N_INSTANCES],
    int samFreq, int startUp,
    asynchronous_fifo_t * unsafe async_fifo_state_play,
    asynchronous_fifo_t * unsafe async_fifo_state_rec)
{

    unsigned char srChange;

    int srcInputBuff_play[SRC_N_INSTANCES][SRC_N_IN_SAMPLES][SRC_CHANNELS_PER_INSTANCE];
    int32_t srcOutputBuff_rec[EXTRA_I2S_CHAN_COUNT_IN];
    int sampleIdx_play = 0;
    float floatRatio_play = (float) samFreq/(float) SAMPLE_FREQUENCY;
    /* Q60 representations of the above */
    uint64_t fsRatio_play = (uint64_t) (floatRatio_play * (1LL << 60));
    int idealFsRatio_play = (fsRatio_play + (1<<31)) >> 32;
    timer t;

    src_task_t srcTask_play;
    srcTask_play.xscopeUsed = 0;
    srcTask_play.fsRatio = fsRatio_play;
    srcTask_play.idealFsRatio = idealFsRatio_play;

#if LOG_CONTROLLER_PLAY
    int logCounterDelay = 0;
    int logCounterGo = 0;
#endif
    if(!startUp)
        /* Handshsake that we are ready to go after SR change */
        /* OR inital request for usb data */
        outct(c_usb, XS1_CT_END);

    while (1)
    {
        select
        {
            case inuchar_byref(c_usb, srChange):

                if(srChange)
                {
                    samFreq = inuint(c_usb);
                    inct(c_usb);

                    /* Return new sample frequency we need to switch to */
                    return samFreq;
                }
                else
                {
                    unsigned now;
                    t :> now;

                    /* Receive samples from USB audio (other side of the UserBufferManagement() comms) */
#pragma loop unroll
                    for(size_t i = 0; i< EXTRA_I2S_CHAN_COUNT_OUT; i++)
                    {
                        srcInputBuff_play[i/SRC_CHANNELS_PER_INSTANCE][sampleIdx_play][i % SRC_CHANNELS_PER_INSTANCE] = inuint(c_usb);
                    }
                    chkct(c_usb, XS1_CT_END);

                    asynchronous_fifo_consumer_get(async_fifo_state_rec, srcOutputBuff_rec, now);

                    /* Send samples to USB audio (other side of the UserBufferManagement() comms */
#pragma loop unroll
                    for(size_t i = 0; i< EXTRA_I2S_CHAN_COUNT_IN; i++)
                    {
                        outuint(c_usb, srcOutputBuff_rec[i]);
                    }
                    outct(c_usb, XS1_CT_END);

                    sampleIdx_play++;

                    if(sampleIdx_play == SRC_N_IN_SAMPLES)
                    {
                        sampleIdx_play = 0;
#if LOG_CONTROLLER_PLAY
                        logCounterDelay ++;

                        if(logCounterGo)
                            logCounterSubPlay++;
                        if(logCounterDelay > CONT_LOG_DELAY)
                             logCounterGo = 1;

                        if(logCounterSubPlay == CONT_LOG_SUBSAMPLE)
                        unsafe{
                            logCounterSubPlay = 0;
                            int fillPlay = (async_fifo_state_play->write_ptr - async_fifo_state_play->read_ptr + async_fifo_state_play->max_fifo_depth)
                                % async_fifo_state_play->max_fifo_depth;
                            r_p[logCounterPlay] = fsRatio_play;

                            logCounterPlay++;

                            if(logCounterPlay >= CONT_LOG_SIZE)
                            {
                                if(logCounterGo)
                                {
                                    for(int i = 0; i < CONT_LOG_SIZE; i++)
                                    {
                                        float ratio = (float) r_p[i] / (float) (1LL<<60);
                                        printf("%f\n", ratio);
                                    }
                                    exit(1);
                                }
                                else
                                    logCounterPlay = 0;
                            }
                        }
#endif

#if (EXTRA_I2S_CHAN_COUNT_OUT > 0)
                        /* Send samples to SRC tasks. This function adds returned sample to FIFO */
                        src_trigger(c_src_play, srcInputBuff_play, async_fifo_state_play, now, &srcTask_play);
#endif
                    }
                }
                break;

        }
    }

__builtin_unreachable();
    /* Should never get here */
    return 0;
}

void i2s_driver(chanend c_usb)
{
    interface i2s_frame_callback_if i_i2s;
    streaming chan c_src_play[SRC_N_INSTANCES];
    streaming chan c_src_rec[SRC_N_INSTANCES];

    set_port_clock(p_off_bclk, clk_bclk);

    int usbSr = DEFAULT_FREQ;
    int startUp = 1;

    unsafe
    {
        asynchronous_fifo_t * unsafe async_fifo_state_play = (asynchronous_fifo_t *)array;
        asynchronous_fifo_t * unsafe async_fifo_state_rec = (asynchronous_fifo_t *)array_rec;

        asynchronous_fifo_init(async_fifo_state_play, 2, FIFO_LENGTH);
        asynchronous_fifo_init(async_fifo_state_rec, 2, FIFO_LENGTH);

        asynchronous_fifo_init_PID_fs_codes(async_fifo_state_play, sr_to_fscode(usbSr), sr_to_fscode(SAMPLE_FREQUENCY));
        asynchronous_fifo_init_PID_fs_codes(async_fifo_state_rec, sr_to_fscode(SAMPLE_FREQUENCY), sr_to_fscode(usbSr));

        par
        {
            par
            {
                [[distribute]]i2s_data(i_i2s, c_src_rec, async_fifo_state_play, async_fifo_state_rec);
                i2s_frame_slave(i_i2s, p_i2s_dout, (EXTRA_I2S_CHAN_COUNT_OUT/2), p_i2s_din, (EXTRA_I2S_CHAN_COUNT_IN/2), DATA_BITS, p_i2s_bclk, p_i2s_lrclk, clk_bclk);
            }
            while(1)
            {

                /* This task produces into fifo for play and consumes from fifo for record */
                usbSr = src_manager(c_usb, c_src_play, usbSr, startUp, async_fifo_state_play, async_fifo_state_rec);
                startUp = 0;

                unsafe
                {
                    *g_usbSamFreqPtr = usbSr;
                }

#if(EXTRA_I2S_CHAN_COUNT_OUT > 0)
                asynchronous_fifo_reset_producer(async_fifo_state_play);
                asynchronous_fifo_init_PID_fs_codes(async_fifo_state_play, sr_to_fscode(usbSr), sr_to_fscode(SAMPLE_FREQUENCY));

                src_change_worker_freqs(c_src_play, SRC_N_INSTANCES, usbSr, 48000);
#endif
            }

#if(EXTRA_I2S_CHAN_COUNT_OUT > 0)
            /* Playback SRC tasks */
            src_task(c_src_play, SRC_N_INSTANCES, DEFAULT_FREQ, 48000);
#endif
#if(EXTRA_I2S_CHAN_COUNT_IN > 0)
            /* Record SRC tasks */
            src_task(c_src_rec, SRC_N_INSTANCES, 48000, DEFAULT_FREQ);
#endif
        } /* par */
    } /* unsafe */
}
