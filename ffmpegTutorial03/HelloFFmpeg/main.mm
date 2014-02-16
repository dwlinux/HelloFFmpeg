//
//  main.mm
//  HelloFFmpeg
//
//  Created by burt on 2014. 2. 13..
//  Copyright (c) 2014년 burt. All rights reserved.
//

#include "main.h"
#include <SDL/SDL.h>
#include <SDL/SDL_thread.h>
#include "SDLMain.h"

/**
 @see http://stackoverflow.com/questions/4585847/g-linking-error-on-mac-while-compiling-ffmpeg
 */
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>
}


#define	SDL_AUDIO_BUFFER_SIZE	1024
#define MAX_AUDIO_FRAME_SIZE	192000

typedef struct PacketQueue
{
	AVPacketList *first_pkt, *last_pkt;
	int nb_packets;
	int size;
	SDL_mutex *mutex;
	SDL_cond	  *cond;
} PacketQueue;

PacketQueue audioq;
int quit = 0;

void packet_queue_init(PacketQueue *q)
{
	memset(q, 0, sizeof(PacketQueue));
	q->mutex = SDL_CreateMutex();
	q->cond = SDL_CreateCond();
}

int packet_queue_put(PacketQueue *q, AVPacket *pkt)
{
	AVPacketList *pkt1 = NULL;
	if(av_dup_packet(pkt) < 0)
		return -1;
	
	pkt1 = (AVPacketList *)av_malloc(sizeof(AVPacketList));
	if(!pkt1)
		return -1;
	
	pkt1->pkt = *pkt;
	pkt1->next = NULL;
	
	SDL_LockMutex(q->mutex);
	
	if(!q->last_pkt)
	{
		q->first_pkt = pkt1;
	}
	else
	{
		q->last_pkt->next = pkt1;
	}
	q->last_pkt = pkt1;
	q->nb_packets++;
	q->size += pkt1->pkt.size;
	SDL_CondSignal(q->cond);

	SDL_UnlockMutex(q->mutex);
	return 0;
}

static int packet_queue_get(PacketQueue *q, AVPacket *pkt, int block)
{
	AVPacketList *pkt1;
	int ret;
	
	SDL_LockMutex(q->mutex);
	
	for(;;)
	{
		if(quit)
		{
			ret = -1;
			break;
		}
		
		pkt1 = q->first_pkt;
		if(pkt1)
		{
			q->first_pkt = pkt1->next;
			if(!q->first_pkt)
				q->last_pkt = NULL;
			q->nb_packets--;
			q->size -= pkt1->pkt.size;
			*pkt = pkt1->pkt;
			av_free(pkt1);
			ret = 1;
			break;
		}
		else if(!block)
		{
			ret = 0;
			break;
		}
		else
		{
			SDL_CondWait(q->cond, q->mutex);
		}
	}
	SDL_UnlockMutex(q->mutex);
	return ret;
}

int audio_decode_frame(AVCodecContext *aCodecCtx, uint8_t *audio_buf, int buf_size)
{
	static AVPacket pkt;
	static uint8_t *audio_pkt_data = NULL;
	static int audio_pkt_size = 0;
	static AVFrame frame;
	
	int len1, data_size = 0;
	
	for(;;)
	{
		while(audio_pkt_size > 0)
		{
			int got_frame = 0;
			len1 = avcodec_decode_audio4(aCodecCtx, &frame, &got_frame, &pkt);
			if(len1 < 0)
			{
				audio_pkt_size = 0;
				break;
			}
			audio_pkt_data += len1;
			audio_pkt_size -= len1;
			
			if(got_frame)
			{
				data_size = av_samples_get_buffer_size
				(
				 NULL,
				 aCodecCtx->channels,
				 frame.nb_samples,
				 aCodecCtx->sample_fmt,
				 1
				);
				memcpy(audio_buf, frame.data[0], data_size);
			}
			
			if(data_size <= 0)
			{
				// No data yet, get more frames */
				continue;
			}
			// We have data, return it and come back for more later
			return data_size;
		}
		
		if(pkt.data)
		{
			av_free_packet(&pkt);
		}
		
		if(quit)
		{
			return -1;
		}
		
		if(packet_queue_get(&audioq, &pkt, 1) < 0)
		{
			return -1;
		}
		audio_pkt_data = pkt.data;
		audio_pkt_size = pkt.size;
	}
}


void audio_callback(void *userdata, uint8_t *stream, int len)
{
	AVCodecContext *aCodecCtx = (AVCodecContext *)userdata;
	int len1, audio_size;
	
	static uint8_t audio_buf[(MAX_AUDIO_FRAME_SIZE * 3)/2];
	static unsigned int audio_buf_size = 0;
	static unsigned int audio_buf_index = 0;
	
	while(len>0)
	{
		if(audio_buf_index >= audio_buf_size)
		{
			// We have already sent all our data; get more
			audio_size = audio_decode_frame(aCodecCtx, audio_buf, audio_buf_size);
			if(audio_size < 0)
			{
				// if error, output silence
				audio_buf_size = 1024; // arbitrary?
				memset(audio_buf, 0, audio_buf_size);
			}
			else
			{
				audio_buf_size = audio_size;
			}
			audio_buf_index = 0;
		}
		len1 = audio_buf_size - audio_buf_index;
		if(len1 > len)
		{
			len1 = len;
		}
		memcpy(stream, (uint8_t *)audio_buf + audio_buf_index, len1);
		len -= len1;
		stream += len1;
		audio_buf_index += len1;
	}
}

int main(int argc, char **argv)
{
	AVFormatContext *pFormatCtx = NULL;
	int             i, videoStream, audioStream;
	AVCodecContext  *pCodecCtx = NULL;
	AVCodec         *pCodec = NULL;
	AVFrame         *pFrame = NULL;
	AVPacket        packet;
	int             frameFinished;
//	float           aspect_ratio;

	AVCodecContext	*aCodecCtx	= NULL;
	AVCodec			*aCodec		= NULL;
	
	int				sws_flags = SWS_BICUBIC;
	struct SwsContext *sws_ctx = NULL;

	
	SDL_Overlay     *bmp = NULL;
	SDL_Surface     *screen = NULL;
	SDL_Rect        rect;
	SDL_Event       event;
	SDL_AudioSpec	wanted_spec, spec;
	
	AVDictionary		*videoOptionDict	= NULL;
	AVDictionary		*audioOptionDict	= NULL;

	if( argc < 2 )
	{
		fprintf(stderr, "Usage: test <file>\n");
		exit(1);
	}
	
	av_register_all();

	if(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_TIMER))
	{
		fprintf(stderr, "Could not initialize SDL - %s\n", SDL_GetError());
		exit(1);
	}
	
	// Open video file
	if(avformat_open_input(&pFormatCtx, argv[1], 0, NULL) != 0)
	{
		// Couldn't open file
		return -1;
	}
	
	// Retrieve stream information
	if(avformat_find_stream_info(pFormatCtx, NULL) < 0)
	{
		// Couldn't find stream information
		return -1;
	}
	
	// Dump information about file onto standard error
	av_dump_format(pFormatCtx, 0, argv[1], 0);
		
	//Find the first video stream
	videoStream = -1;
	audioStream = -1;
	for(i=0; i<pFormatCtx->nb_streams; i++)
	{
		if(pFormatCtx->streams[i]->codec->codec_type == AVMEDIA_TYPE_VIDEO && videoStream < 0)
		{
			videoStream = i;
		}
		
		if(pFormatCtx->streams[i]->codec->codec_type == AVMEDIA_TYPE_AUDIO && audioStream < 0)
		{
			audioStream = i;
		}
	}
	
	if(videoStream == -1)
	{
		// Didn't find a video stream
		return -1;
	}
	
	if(audioStream == -1)
	{
		return -1;
	}
	
	aCodecCtx = pFormatCtx->streams[audioStream]->codec;
	// Set audio settings from codec info
	wanted_spec.freq = aCodecCtx->sample_rate;
	wanted_spec.format = AUDIO_S16SYS;
	wanted_spec.channels = aCodecCtx->channels;
	wanted_spec.silence = 0;
	wanted_spec.samples = SDL_AUDIO_BUFFER_SIZE;
	wanted_spec.callback= audio_callback;
	wanted_spec.userdata= aCodecCtx;
	
	if(SDL_OpenAudio(&wanted_spec, &spec) < 0)
	{
		fprintf(stderr, "SDL_OpenAudio: %s\n", SDL_GetError());
		return -1;
	}
	aCodec = avcodec_find_decoder(aCodecCtx->codec_id);
	if(!aCodec)
	{
		fprintf(stderr, "Unsupported codec!\n");
		return -1;
	}
	avcodec_open2(aCodecCtx, aCodec, &audioOptionDict);
	
	// audio_st = pFormatCtx->streams[index];
	packet_queue_init(&audioq);
	SDL_PauseAudio(0);
	
	// Get a pointer to the codec context for the video stream
	pCodecCtx = pFormatCtx->streams[videoStream]->codec;
	
	
	// Find the decoder for the video stream
	pCodec = avcodec_find_decoder(pCodecCtx->codec_id);
	if(pCodec == NULL)
	{
		// Codec not found
		fprintf(stderr, "Unsupported codec!\n");
		return -1;
	}
	
	//Open codec
	if(avcodec_open2(pCodecCtx, pCodec, NULL) < 0)
	{
		// Could not open codec
		return -1;
	}
	
	// Allocate video frame
	pFrame = avcodec_alloc_frame();
	
	screen = SDL_SetVideoMode(pCodecCtx->width, pCodecCtx->height, 0, 0);
	if(!screen)
	{
		fprintf(stderr, "SDL: could not set video mode - exiting\n");
		exit(1);
	}
	
	bmp = SDL_CreateYUVOverlay(pCodecCtx->width, pCodecCtx->height, SDL_YV12_OVERLAY, screen);
	
	i=0;
	while (av_read_frame(pFormatCtx, &packet) >= 0) {
		if(packet.stream_index == videoStream)
		{
			// Decode video frame
			avcodec_decode_video2(pCodecCtx, pFrame, &frameFinished, &packet);
			if(frameFinished)
			{
				SDL_LockYUVOverlay(bmp);
				
				AVPicture pict;
				pict.data[0] = bmp->pixels[0];
				pict.data[1] = bmp->pixels[2];
				pict.data[2] = bmp->pixels[1];
				
				pict.linesize[0] = bmp->pitches[0];
				pict.linesize[1] = bmp->pitches[2];
				pict.linesize[2] = bmp->pitches[1];
				
				// Convert the image into YUV format that SDL uses
				sws_ctx = sws_getContext(pCodecCtx->width, pCodecCtx->height, pCodecCtx->pix_fmt, pCodecCtx->width, pCodecCtx->height, PIX_FMT_YUV420P, sws_flags, NULL, NULL, NULL);
				sws_scale(sws_ctx, pFrame->data, pFrame->linesize, 0, pCodecCtx->height, pict.data, pict.linesize);
				sws_freeContext(sws_ctx);
				
				SDL_UnlockYUVOverlay(bmp);
				
				rect.x = 0;
				rect.y = 0;
				rect.w = pCodecCtx->width;
				rect.h = pCodecCtx->height;
				
				SDL_DisplayYUVOverlay(bmp, &rect);
			}
		}
		
		//Free the packet that was allocated by av_read_frame
		av_free_packet(&packet);
		SDL_PollEvent(&event);
		switch (event.type)
		{
			case SDL_QUIT:
				SDL_Quit();
				break;
			default:
				break;
		}
	}
	
	// Free the YUV frame
	av_free(pFrame);
	
	// Close the codec
	avcodec_close(pCodecCtx);
	
	// Close the video file
	avformat_close_input(&pFormatCtx);
	return 0;
}