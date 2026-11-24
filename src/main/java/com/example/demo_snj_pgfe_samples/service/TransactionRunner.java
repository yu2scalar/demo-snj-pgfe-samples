package com.example.demo_snj_pgfe_samples.service;

import com.example.demo_snj_pgfe_samples.exception.CustomException;
import java.sql.SQLException;
import java.util.function.Supplier;
import lombok.extern.slf4j.Slf4j;
import org.springframework.core.retry.RetryException;
import org.springframework.core.retry.RetryTemplate;
import org.springframework.dao.ConcurrencyFailureException;
import org.springframework.dao.DataAccessException;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.TransactionException;
import org.springframework.transaction.TransactionStatus;

/**
 * One transaction on one DataSource, with retry.
 *
 * There is one runner per DataSource (DataSourceConfig): {@code customerTx}, {@code inventoryTx} and
 * {@code orderingTx} run a local transaction in one database through ScalarDB Native JDBC, and
 * {@code pgfeTx} runs a ScalarDB transaction across the databases through the PostgreSQL Frontend.
 * Which one a service uses is the choice this sample is about.
 *
 * The work runs on the connection bound to the thread by the runner's transaction manager, so the
 * repositories (JdbcTemplate on the same DataSource) take part in it without a transaction parameter.
 * The isolation level is READ COMMITTED (app.datasource.*.transaction-isolation).
 */
@Slf4j
public class TransactionRunner {
    // Commit outcome unknown (as UnknownTransactionStatusException in the ScalarDB Java API)
    public static final int UNKNOWN_TRANSACTION_STATUS = 9200;
    // SQLSTATE statement_completion_unknown: the PostgreSQL Frontend's "commit outcome unknown"
    private static final String COMPLETION_UNKNOWN = "40003";

    private final String name;
    private final PlatformTransactionManager transactionManager;
    private final RetryTemplate retryTemplate;

    public TransactionRunner(String name, PlatformTransactionManager transactionManager, RetryTemplate retryTemplate) {
        this.name = name;
        this.transactionManager = transactionManager;
        this.retryTemplate = retryTemplate;
    }

    public String getName() {
        return name;
    }

    public <T> T run(Supplier<T> work) throws CustomException {
        try {
            return retryTemplate.execute(() -> runOnce(work));
        } catch (RetryException re) {
            Throwable cause = (re.getCause() != null) ? re.getCause() : re;
            throw new CustomException(cause.getMessage(), cause, determineErrorCode(cause));
        }
    }

    /** One transaction without retry. Failures are thrown as they are. */
    public <T> T runOnce(Supplier<T> work) {
        TransactionStatus status = transactionManager.getTransaction(TransactionDefinition.withDefaults());
        T result;
        try {
            result = work.get();
        } catch (RuntimeException | Error e) {
            log.error("[{}] {}", name, e.getMessage(), e);
            try {
                transactionManager.rollback(status);
            } catch (Exception ex) {
                log.error("[{}] {}", name, ex.getMessage(), ex);
            }
            throw e;
        }
        try {
            transactionManager.commit(status);
        } catch (ConcurrencyFailureException | DataIntegrityViolationException e) {
            // The database (or ScalarDB, through the PostgreSQL Frontend) refused the commit and rolled the
            // transaction back: a conflict (40001) is retried, a duplicate key (23505) is not. The PostgreSQL
            // Frontend reports ScalarDB's conflicts at COMMIT, so this case matters there most.
            if (COMPLETION_UNKNOWN.equals(sqlState(e))) {
                throw unknown(e);
            }
            log.warn("[{}] Commit refused, rolled back: {}", name, e.getMessage());
            throw e;
        } catch (TransactionException | DataAccessException e) {
            // E.g. the connection was lost during the commit: it may have been committed. Not retried.
            throw unknown(e);
        }
        return result;
    }

    private CustomException unknown(Exception e) {
        log.error("[{}] {}", name, e.getMessage(), e);
        log.warn("[{}] Commit outcome unknown - the transaction may have been committed. Verify it before retrying.", name);
        return new CustomException("Commit outcome unknown: " + e.getMessage(), e, UNKNOWN_TRANSACTION_STATUS);
    }

    private static String sqlState(Throwable e) {
        for (Throwable c = e; c != null; c = c.getCause()) {
            if (c instanceof SQLException && ((SQLException) c).getSQLState() != null) {
                return ((SQLException) c).getSQLState();
            }
        }
        return null;
    }

    // Same codes as the ScalarDB samples (see CustomException)
    private static int determineErrorCode(Throwable e) {
        for (Throwable c = e; c != null; c = c.getCause()) {
            if (c instanceof CustomException && ((CustomException) c).getErrorCode() != null) {
                return ((CustomException) c).getErrorCode();
            }
        }
        for (Throwable c = e; c != null; c = c.getCause()) {
            // Includes a duplicate key on insert (ScalarDB: a conflict, 9300 after the retries)
            if (c instanceof DataAccessException || c instanceof TransactionException) return 9300;
        }
        if (e instanceof RuntimeException) return 9400;
        return 9500;
    }
}
