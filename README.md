 Локально   : http://localhost:20128                        │
  │  Сеть       : http://ip:20128                   │
  │  Интернет   : http://ip:20128                   │
  │  API Base   : http://ip:20128/v1                │
  │  Модели     : http://ip:20128/v1/models 

  УПРАВЛЕНИЕ
  systemctl status  9router
  systemctl restart 9router
  systemctl stop    9router
  journalctl -u 9router -f
  tail -f /var/log/9router/9router.log

  ФАЙЛЫ
  Бинарник : /usr/bin/9router
  Данные   : /var/lib/9router
  Логи     : /var/log/9router/
  ENV      : /etc/9router/env
  Systemd  : /etc/systemd/system/9router.service
