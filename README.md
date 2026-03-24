### corepost-agent 
post-boot компонент для Linux под systemd.
Он подписывает запросы к серверу, получает политику и применяет действия observe, lock_session, logout или shutdown.
Сервис устанавливается как shell script с systemd unit и env-файлом.
Локальное состояние и ACK timestamp сохраняются в отдельном каталоге состояния.
