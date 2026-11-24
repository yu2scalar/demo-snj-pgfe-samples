package com.example.demo_snj_pgfe_samples.config;

import java.sql.Connection;
import java.util.Map;
import javax.sql.DataSource;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.ApplicationRunner;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Slf4j
@Configuration
public class JdbcConfig {

    // Connects once through every DataSource at start-up and logs what it reached, so that a wrong
    // URL, user or password shows at once rather than on the first request.
    @Bean
    public ApplicationRunner logDatabases(Map<String, DataSource> dataSources) {
        return args -> {
            for (Map.Entry<String, DataSource> e : dataSources.entrySet()) {
                try (Connection connection = e.getValue().getConnection()) {
                    log.info("{}: {} {} ({})", e.getKey(), connection.getMetaData().getDatabaseProductName(),
                        connection.getMetaData().getDatabaseProductVersion(), connection.getMetaData().getURL());
                }
            }
        };
    }
}
