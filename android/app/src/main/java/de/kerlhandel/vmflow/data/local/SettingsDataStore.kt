package de.kerlhandel.vmflow.data.local

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.preferencesDataStore

/** Single DataStore instance per process, exposed via Hilt (see SupabaseModule). */
val Context.appDataStore: DataStore<Preferences> by preferencesDataStore(name = "vmflow_settings")
