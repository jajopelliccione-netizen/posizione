#include <stdint.h>
int32_t ll_connect(const char *pairing_path);
int32_t ll_set_location(double lat, double lon);
int32_t ll_clear_location(void);
void ll_disconnect(void);
char *ll_last_error(void);
void ll_free_string(char *p);
