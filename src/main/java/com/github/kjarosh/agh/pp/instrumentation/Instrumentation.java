package com.github.kjarosh.agh.pp.instrumentation;

import com.github.kjarosh.agh.pp.config.ConfigLoader;
import lombok.Getter;
import lombok.extern.slf4j.Slf4j;

import java.nio.file.Paths;
import java.util.concurrent.BlockingDeque;
import java.util.concurrent.LinkedBlockingDeque;

/**
 * @author Kamil Jarosz
 */
@Slf4j
public class Instrumentation {
    @Getter
    private static final Instrumentation instance = new Instrumentation();

    private static final int BULK_SIZE = 500;
    private static final int QUEUE_CAPACITY = 5 * BULK_SIZE;
    private final boolean enabled = ConfigLoader.getConfig().isInstrumentationEnabled();
    private final BlockingDeque<Notification> notificationQueue = new LinkedBlockingDeque<>(QUEUE_CAPACITY);
    private final Thread handlerThread;
    private final InstrumentationListener listener;

    private Instrumentation() {
        if (!enabled) {
            log.info("Instrumentation disabled");
            this.handlerThread = null;
            this.listener = null;
            return;
        }

        String reportPath = ConfigLoader.getConfig().getInstrumentationReportPath();
        log.info("Instrumentation enabled, writing to {}", reportPath);
        this.listener = new CsvFileInstrumentationListener(Paths.get(reportPath));
        this.handlerThread = new Thread(this::runHandler);
        this.handlerThread.start();
    }

    private void runHandler() {
        try (InstrumentationListener listener = this.listener) {
            listener.open();
            while (!Thread.interrupted()) {
                int size = BULK_SIZE;
                Notification[] bulk = new Notification[BULK_SIZE];
                bulk[0] = notificationQueue.take();

                for (int i = 1; i < BULK_SIZE; ++i) {
                    Notification polled = notificationQueue.poll();
                    if (polled == null) {
                        size = i;
                        break;
                    } else {
                        bulk[i] = polled;
                    }
                }

                listener.handle(bulk, size);
            }
        } catch (InterruptedException e) {
            log.info("Instrumentation notification thread has been interrupted", e);
        }
    }

    public void notify(Notification notification) {
        if (!enabled) return;

        boolean success = notificationQueue.offer(notification);
        if (!success) {
            String message = "Can't keep up with notifications!";
            log.error(message);
            throw new InstrumentationException(message);
        }
    }
}
