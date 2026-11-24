package com.example.demo_snj_pgfe_samples.config;

import com.example.demo_snj_pgfe_samples.repository.CustomerCustomersRepository;
import com.example.demo_snj_pgfe_samples.repository.InventoryItemsRepository;
import com.example.demo_snj_pgfe_samples.repository.OrderingOrdersRepository;
import com.example.demo_snj_pgfe_samples.repository.OrderingStatementsRepository;
import com.example.demo_snj_pgfe_samples.service.TransactionRunner;
import com.zaxxer.hikari.HikariDataSource;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.jdbc.DataSourceBuilder;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.retry.RetryTemplate;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.support.JdbcTransactionManager;

/**
 * Four DataSources, and for each a JdbcTemplate, a transaction manager and a TransactionRunner.
 *
 * <pre>
 *   customer   jdbc:scalardb-native:postgresql://.../db_customer    ScalarDB Native JDBC   customerTx
 *   inventory  jdbc:scalardb-native:postgresql://.../db_inventory   ScalarDB Native JDBC   inventoryTx
 *   ordering   jdbc:scalardb-native:postgresql://.../db_ordering    ScalarDB Native JDBC   orderingTx
 *   pgfe       jdbc:postgresql://<ScalarDB Cluster>:5439/...         PostgreSQL Frontend    pgfeTx
 * </pre>
 *
 * A transaction in one database runs through ScalarDB Native JDBC on that database's DataSource: a
 * local transaction of the database, kept consistent with ScalarDB's transactions on the same rows by
 * the driver. A transaction across the databases runs through the PostgreSQL Frontend of ScalarDB
 * Cluster: one ScalarDB transaction (Consensus Commit) over the three databases, in PostgreSQL's SQL.
 *
 * The repositories are the same classes for both; each is created once per DataSource it is used on.
 * JdbcTransactionManager (not DataSourceTransactionManager) translates a failed COMMIT into Spring's
 * DataAccessException, so that TransactionRunner can tell a refused commit from an unknown outcome.
 */
@Configuration
public class DataSourceConfig {

    // ---- DataSources (app.datasource.<name>.* in application.properties: jdbc-url, username, password, ...)

    @Bean
    @ConfigurationProperties("app.datasource.customer")
    public HikariDataSource customerDataSource() {
        return DataSourceBuilder.create().type(HikariDataSource.class).build();
    }

    @Bean
    @ConfigurationProperties("app.datasource.inventory")
    public HikariDataSource inventoryDataSource() {
        return DataSourceBuilder.create().type(HikariDataSource.class).build();
    }

    @Bean
    @ConfigurationProperties("app.datasource.ordering")
    public HikariDataSource orderingDataSource() {
        return DataSourceBuilder.create().type(HikariDataSource.class).build();
    }

    @Bean
    @ConfigurationProperties("app.datasource.pgfe")
    public HikariDataSource pgfeDataSource() {
        return DataSourceBuilder.create().type(HikariDataSource.class).build();
    }

    // ---- TransactionRunners: which transaction a service runs in

    @Bean
    public TransactionRunner customerTx(@Qualifier("customerDataSource") HikariDataSource ds,
            @Qualifier("jdbcRetryTemplate") RetryTemplate retry) {
        return new TransactionRunner("customerTx (SNJ, db_customer)", new JdbcTransactionManager(ds), retry);
    }

    @Bean
    public TransactionRunner inventoryTx(@Qualifier("inventoryDataSource") HikariDataSource ds,
            @Qualifier("jdbcRetryTemplate") RetryTemplate retry) {
        return new TransactionRunner("inventoryTx (SNJ, db_inventory)", new JdbcTransactionManager(ds), retry);
    }

    @Bean
    public TransactionRunner orderingTx(@Qualifier("orderingDataSource") HikariDataSource ds,
            @Qualifier("jdbcRetryTemplate") RetryTemplate retry) {
        return new TransactionRunner("orderingTx (SNJ, db_ordering)", new JdbcTransactionManager(ds), retry);
    }

    @Bean
    public TransactionRunner pgfeTx(@Qualifier("pgfeDataSource") HikariDataSource ds,
            @Qualifier("jdbcRetryTemplate") RetryTemplate retry) {
        return new TransactionRunner("pgfeTx (PGFE, across the databases)", new JdbcTransactionManager(ds), retry);
    }

    // ---- Repositories through ScalarDB Native JDBC: each on the DataSource of its own database

    @Bean
    public CustomerCustomersRepository customersSnj(@Qualifier("customerDataSource") HikariDataSource ds) {
        return new CustomerCustomersRepository(new JdbcTemplate(ds));
    }

    @Bean
    public InventoryItemsRepository itemsSnj(@Qualifier("inventoryDataSource") HikariDataSource ds) {
        return new InventoryItemsRepository(new JdbcTemplate(ds));
    }

    @Bean
    public OrderingOrdersRepository ordersSnj(@Qualifier("orderingDataSource") HikariDataSource ds) {
        return new OrderingOrdersRepository(new JdbcTemplate(ds));
    }

    @Bean
    public OrderingStatementsRepository statementsSnj(@Qualifier("orderingDataSource") HikariDataSource ds) {
        return new OrderingStatementsRepository(new JdbcTemplate(ds));
    }

    // ---- Repositories through the PostgreSQL Frontend: all on the one PGFE DataSource

    @Bean
    public CustomerCustomersRepository customersPgfe(@Qualifier("pgfeDataSource") HikariDataSource ds) {
        return new CustomerCustomersRepository(new JdbcTemplate(ds));
    }

    @Bean
    public InventoryItemsRepository itemsPgfe(@Qualifier("pgfeDataSource") HikariDataSource ds) {
        return new InventoryItemsRepository(new JdbcTemplate(ds));
    }

    @Bean
    public OrderingOrdersRepository ordersPgfe(@Qualifier("pgfeDataSource") HikariDataSource ds) {
        return new OrderingOrdersRepository(new JdbcTemplate(ds));
    }

    @Bean
    public OrderingStatementsRepository statementsPgfe(@Qualifier("pgfeDataSource") HikariDataSource ds) {
        return new OrderingStatementsRepository(new JdbcTemplate(ds));
    }
}
