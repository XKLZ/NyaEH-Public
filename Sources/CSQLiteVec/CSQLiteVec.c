#include "CSQLiteVec.h"

int nyaeh_sqlite_vec_init(sqlite3 *db) {
    return sqlite3_vec_init(db, 0, 0);
}
